# -*- coding: utf-8 -*-
"""
Convert AuraFace ONNX weights into a Core ML model for the iOS app.

Input:
- C:/tmp/glintr100.onnx

Output:
- ../xcode-face-auth/iOS-Face-Auth-AI/AuraFace.mlmodel
"""

import io
import os
import sys

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8")

import coremltools as ct
import onnx
import torch
from onnx2torch import convert as onnx2torch_convert
from coremltools.models.neural_network import quantization_utils


ONNX_PATH = "C:/tmp/glintr100.onnx"
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAVE_DIR = os.path.dirname(os.path.abspath(__file__))
SAVE_PATH = os.path.join(SAVE_DIR, "AuraFace.mlmodel")


def main() -> None:
    print("=" * 50)
    print("AuraFace v1 -> Core ML conversion")
    print("  ONNX -> PyTorch -> TorchScript -> Core ML")
    print("=" * 50)

    if not os.path.exists(ONNX_PATH):
        raise FileNotFoundError(f"ONNX model not found: {ONNX_PATH}")

    print(f"\n[1/5] Loading ONNX model: {ONNX_PATH}")
    print(f"  Size: {os.path.getsize(ONNX_PATH) / 1024 / 1024:.1f} MB")

    onnx_model = onnx.load(ONNX_PATH, load_external_data=False)
    model = onnx2torch_convert(onnx_model)
    model.eval()

    print("  [OK] Converted ONNX to PyTorch")
    print(f"  Parameters: {sum(p.numel() for p in model.parameters()):,}")

    print("\n[2/5] Running a smoke test...")
    dummy_input = torch.randn(1, 3, 112, 112)
    with torch.no_grad():
        output = model(dummy_input)
        norm = torch.norm(output, dim=1)
    print(f"  Output shape: {tuple(output.shape)}")
    print(f"  L2 norm: {norm.item():.4f}")

    print("\n[3/5] Tracing TorchScript...")
    with torch.no_grad():
        traced = torch.jit.trace(model, dummy_input)
    print("  [OK] TorchScript ready")

    print("\n[4/5] Converting to Core ML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="face_input",
                shape=(1, 3, 112, 112),
                color_layout=ct.colorlayout.BGR,
                bias=[-1.0, -1.0, -1.0],
                scale=1.0 / (255.0 * 0.5),
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="neuralnetwork",
        minimum_deployment_target=ct.target.iOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    print("  [OK] Core ML conversion complete")

    print("  Applying Float16 quantization...")
    mlmodel = quantization_utils.quantize_weights(mlmodel, nbits=16)
    print("  [OK] Float16 quantization complete")

    print("\n[5/5] Saving model...")
    os.makedirs(SAVE_DIR, exist_ok=True)
    mlmodel.short_description = "AuraFace v1 Face Embedding (512-dim, Apache-2.0)"
    mlmodel.author = "fal (https://huggingface.co/fal/AuraFace-v1)"
    mlmodel.version = "1.0"
    mlmodel.license = "Apache-2.0"
    mlmodel.input_description["face_input"] = "112x112 BGR face image (cropped, aligned)"
    mlmodel.output_description["embedding"] = "512-dim L2-normalized face embedding"

    ct.utils.save_spec(mlmodel.get_spec(), SAVE_PATH)

    size_mb = os.path.getsize(SAVE_PATH) / 1024 / 1024
    print("=" * 50)
    print(f"  File: {SAVE_PATH}")
    print(f"  Size: {size_mb:.1f} MB")
    print("  Embedding: 512-dim")
    print("  Input: 112x112 BGR")
    print("  License: Apache-2.0")
    print("=" * 50)


if __name__ == "__main__":
    main()
