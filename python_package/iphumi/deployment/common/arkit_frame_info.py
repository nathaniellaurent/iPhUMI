"""
Frame info messages the iOS app sends on the depth port (5557) when Deployment's Capture Source is "ARKit".

One message per sent ARFrame, right after that frame's JPEG on the main port (5555). Layout (little-endian), as
written by ios_app/iPhUMI/Deployment/ARKitStreamer.swift:

    offset  size  field
         0     4  magic b"ARKD"
         4     4  u32 version (1)
         8     4  u32 header size in bytes (132); depth values start here
        12     8  u64 frame index (counts sent frames from 0)
        20     8  f64 ARFrame.timestamp (seconds since the phone booted)
        28     8  u32 x2 width, height of ARKit's full color image (the intrinsics refer to this size)
        36     8  u32 x2 depth width, height (0, 0 when depth is off)
        44    16  f32 x4 fx, fy, cx, cy in pixels of the full color image
        60    64  f32 x16 camera transform (camera to world), column-major
       124     4  u32 tracking state: 0 not available, 1 limited, 2 normal
       128     4  u32 1 if a confidence map follows the depth, else 0
       132        f32 depth in metres, row by row (depth height x width)
                  u8 confidence (0 low, 1 medium, 2 high), same size, if flagged

Usage:
    from iphumi.deployment.common.arkit_frame_info import is_frame_info, parse_frame_info

    if is_frame_info(message):
        info = parse_frame_info(message)
        K = info.intrinsics_for(width=256, height=192)  # e.g. for the depth map, which has the color image's view
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

import numpy as np

MAGIC = b"ARKD"
_FIXED = struct.Struct("<4sIIQdIIIIffff16fII")
TRACKING_STATES = {0: "not available", 1: "limited", 2: "normal"}


@dataclass
class ARKitFrameInfo:
    frame_index: int
    timestamp: float
    image_size: tuple[int, int]  # (width, height) of ARKit's full color image
    fx: float
    fy: float
    cx: float
    cy: float
    camera_to_world: np.ndarray  # (4, 4) float32
    tracking_state: int
    depth: np.ndarray | None  # (height, width) float32 metres
    confidence: np.ndarray | None  # (height, width) uint8

    def intrinsics_for(self, width: int, height: int) -> np.ndarray:
        """3x3 intrinsics for an image of the same view resized to (width, height), e.g. the streamed JPEG or the depth map."""
        sx = width / self.image_size[0]
        sy = height / self.image_size[1]
        return np.array(
            [[self.fx * sx, 0.0, self.cx * sx], [0.0, self.fy * sy, self.cy * sy], [0.0, 0.0, 1.0]],
            dtype=np.float64,
        )


def is_frame_info(message: bytes) -> bool:
    return message[:4] == MAGIC


def parse_frame_info(message: bytes) -> ARKitFrameInfo:
    if len(message) < _FIXED.size or not is_frame_info(message):
        raise ValueError(f"not an ARKit frame info message ({len(message)} bytes)")
    fields = _FIXED.unpack_from(message)
    _, version, header_size, frame_index, timestamp, img_w, img_h, depth_w, depth_h = fields[:9]
    fx, fy, cx, cy = fields[9:13]
    transform = np.array(fields[13:29], dtype=np.float32).reshape(4, 4).T  # sent column by column
    tracking_state, has_confidence = fields[29:31]
    if version != 1:
        raise ValueError(f"unsupported ARKit frame info version {version}")

    n = depth_w * depth_h
    expected = header_size + n * 4 + (n if has_confidence else 0)
    if len(message) != expected:
        raise ValueError(f"ARKit frame info is {len(message)} bytes, expected {expected}")
    depth = confidence = None
    if n:
        depth = np.frombuffer(message, dtype="<f4", count=n, offset=header_size).reshape(depth_h, depth_w)
        if has_confidence:
            confidence = np.frombuffer(message, dtype=np.uint8, count=n, offset=header_size + n * 4).reshape(
                depth_h, depth_w
            )
    return ARKitFrameInfo(
        frame_index=frame_index,
        timestamp=timestamp,
        image_size=(img_w, img_h),
        fx=fx,
        fy=fy,
        cx=cx,
        cy=cy,
        camera_to_world=transform,
        tracking_state=tracking_state,
        depth=depth,
        confidence=confidence,
    )
