# -*- coding: utf-8 -*-
"""
AuraFace -> Core ML 변환 스크립트
--------------------------------------
모델: AuraFace v1 (fal/AuraFace-v1)
아키텍처: ResNet100 + ArcFace (GlintR100)
라이선스: Apache-2.0 (상업적 사용 가능)
임베딩: 512차원 (L2 정규화)

변환 경로: ONNX -> PyTorch -> TorchScript -> Core ML

실행: .venv\Scripts\python.exe convert_auraface.py
결과: AuraFace.mlmodel (프로젝트 폴더에 생성)
"""

import sys
import io
import os

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import onnx
import torch
import coremltools as ct
from onnx2torch import convert as onnx2torch_convert

# ──────────────────────────────────────────
# 1. ONNX -> PyTorch 변환
# ──────────────────────────────────────────

print("=" * 50)
print("AuraFace v1 -> Core ML 변환")
print("  ONNX -> PyTorch -> TorchScript -> Core ML")
print("=" * 50)

onnx_path = "C:/temp/glintr100.onnx"
print(f"\n[1/5] ONNX 모델 로드: {onnx_path}")
print(f"  파일 크기: {os.path.getsize(onnx_path) / 1024 / 1024:.1f} MB")

# load_external_data=False: Windows에서 ONNX temp file 버그 회피
onnx_model = onnx.load(onnx_path, load_external_data=False)
model = onnx2torch_convert(onnx_model)
model.eval()
print("  [OK] PyTorch 모델로 변환 완료 (사전학습 가중치 포함)")
print(f"  파라미터 수: {sum(p.numel() for p in model.parameters()):,}")

# ──────────────────────────────────────────
# 2. 동작 확인
# ──────────────────────────────────────────

print("\n[2/5] 사전학습 모델 동작 확인...")
dummy_input = torch.randn(1, 3, 112, 112)
with torch.no_grad():
    output = model(dummy_input)
    print(f"  출력 형태: {output.shape}")
    norm = torch.norm(output, dim=1)
    print(f"  L2 norm: {norm.item():.4f}")

# ──────────────────────────────────────────
# 3. TorchScript 변환
# ──────────────────────────────────────────

print("\n[3/5] TorchScript 변환 중...")
with torch.no_grad():
    traced = torch.jit.trace(model, dummy_input)
print("  [OK] TorchScript 완료")

# ──────────────────────────────────────────
# 4. Core ML 변환 + Float16 양자화
# ──────────────────────────────────────────

print("\n[4/5] Core ML 변환 중...")

# AuraFace/InsightFace 정규화: (pixel/255 - 0.5) / 0.5
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
print("  [OK] Core ML 변환 완료")

print("  Float16 양자화 적용 중...")
from coremltools.models.neural_network import quantization_utils
mlmodel = quantization_utils.quantize_weights(mlmodel, nbits=16)
print("  [OK] Float16 양자화 완료")

# ──────────────────────────────────────────
# 5. 메타데이터 추가 및 저장
# ──────────────────────────────────────────

mlmodel.short_description = "AuraFace v1 Face Embedding (512-dim, Apache-2.0)"
mlmodel.author            = "fal (https://huggingface.co/fal/AuraFace-v1)"
mlmodel.version           = "1.0"
mlmodel.license           = "Apache-2.0"
mlmodel.input_description["face_input"] = "112x112 BGR face image (cropped, aligned)"
mlmodel.output_description["embedding"] = "512-dim L2-normalized face embedding"

save_path = "AuraFace.mlmodel"
ct.utils.save_spec(mlmodel.get_spec(), save_path)

size_mb = os.path.getsize(save_path) / 1024 / 1024

print(f"\n[5/5] 저장 완료!")
print("=" * 50)
print(f"  파일: {save_path}")
print(f"  크기: {size_mb:.1f} MB")
print(f"  임베딩: 512차원")
print(f"  입력: 112x112 BGR")
print(f"  라이선스: Apache-2.0 (상업적 사용 가능)")
print("=" * 50)
print("\n[iOS 코드 수정사항]")
print("  1. 모델: MobileFaceNet.mlmodel -> AuraFace.mlmodel")
print("  2. 임베딩 차원: 128 -> 512")
print("  3. 유사도 임계값: 0.4~0.5 범위로 재조정")
