# -*- coding: utf-8 -*-
"""
MobileFaceNet -> Core ML 변환 스크립트
--------------------------------------
실행: python convert_model.py
결과: MobileFaceNet.mlmodel (프로젝트 폴더에 생성)
"""

import sys
import io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

import torch
import torch.nn as nn
import coremltools as ct
import coremltools.optimize.coreml as cto
import os

# ──────────────────────────────────────────
# 1. MobileFaceNet 아키텍처 정의
#    (foamliu/MobileFaceNet 체크포인트 호환)
# ──────────────────────────────────────────

class InvertedResidual(nn.Module):
    """MobileNetV2-스타일 Inverted Residual 블록 (ReLU6 활성화)"""
    def __init__(self, in_c, out_c, stride, expand_ratio):
        super().__init__()
        self.use_res_connect = (stride == 1 and in_c == out_c)
        hidden_dim = in_c * expand_ratio

        # 체크포인트 키 구조에 맞춘 nested Sequential:
        # conv.0.0 = Conv2d, conv.0.1 = BN, conv.0.2 = ReLU6  (pointwise expand)
        # conv.1.0 = Conv2d, conv.1.1 = BN, conv.1.2 = ReLU6  (depthwise)
        # conv.2   = Conv2d  (pointwise project)
        # conv.3   = BN      (project BN)
        self.conv = nn.Sequential(
            # [0] Pointwise Expand
            nn.Sequential(
                nn.Conv2d(in_c, hidden_dim, 1, 1, 0, bias=False),
                nn.BatchNorm2d(hidden_dim),
                nn.ReLU6(inplace=True),
            ),
            # [1] Depthwise
            nn.Sequential(
                nn.Conv2d(hidden_dim, hidden_dim, 3, stride, 1, groups=hidden_dim, bias=False),
                nn.BatchNorm2d(hidden_dim),
                nn.ReLU6(inplace=True),
            ),
            # [2] Pointwise Project (선형 — 활성화 없음)
            nn.Conv2d(hidden_dim, out_c, 1, 1, 0, bias=False),
            # [3] Project BN
            nn.BatchNorm2d(out_c),
        )

    def forward(self, x):
        if self.use_res_connect:
            return x + self.conv(x)
        else:
            return self.conv(x)


class GDConv(nn.Module):
    """Global Depthwise Convolution — 7x7 depthwise + BN"""
    def __init__(self, in_c, kernel_size=7):
        super().__init__()
        self.depthwise = nn.Conv2d(in_c, in_c, kernel_size, 1, 0, groups=in_c, bias=False)
        self.bn = nn.BatchNorm2d(in_c)

    def forward(self, x):
        x = self.depthwise(x)
        x = self.bn(x)
        return x


class DepthwiseSeparableConv(nn.Module):
    """Depthwise Separable Convolution — depthwise + pointwise + BN + BN"""
    def __init__(self, in_c, out_c, kernel_size=3, stride=1, padding=1):
        super().__init__()
        self.depthwise = nn.Conv2d(in_c, in_c, kernel_size, stride, padding, groups=in_c, bias=False)
        self.pointwise = nn.Conv2d(in_c, out_c, 1, 1, 0, bias=False)
        self.bn1 = nn.BatchNorm2d(in_c)
        self.bn2 = nn.BatchNorm2d(out_c)

    def forward(self, x):
        x = self.depthwise(x)
        x = self.bn1(x)
        x = self.pointwise(x)
        x = self.bn2(x)
        return x


class MobileFaceNet(nn.Module):
    """
    foamliu/MobileFaceNet 호환 아키텍처
    - 입력: 112x112 RGB
    - 출력: 128차원 임베딩 벡터
    - Bottleneck 설정: [t, c, n, s]
      [2, 64,  5, 2]  # features.0-4   (56→28)
      [4, 128, 1, 2]  # features.5     (28→14)
      [2, 128, 6, 1]  # features.6-11  (14→14)
      [4, 128, 1, 2]  # features.12    (14→7)
      [2, 128, 2, 1]  # features.13-14 (7→7)
    """
    def __init__(self, embedding_size=128):
        super().__init__()

        # 초기 Conv: 3→64, stride=2 (112→56)
        self.conv1 = nn.Sequential(
            nn.Conv2d(3, 64, 3, 2, 1, bias=False),
            nn.BatchNorm2d(64),
        )

        # Depthwise Separable Conv: 64→64 (56→56)
        self.dw_conv = DepthwiseSeparableConv(64, 64, 3, 1, 1)

        # Bottleneck 설정: (expansion, out_channels, num_blocks, stride)
        bottleneck_setting = [
            [2, 64,  5, 2],   # features.0-4:   56→28
            [4, 128, 1, 2],   # features.5:     28→14
            [2, 128, 6, 1],   # features.6-11:  14→14
            [4, 128, 1, 2],   # features.12:    14→7
            [2, 128, 2, 1],   # features.13-14: 7→7
        ]

        # InvertedResidual 블록 생성
        features = []
        in_c = 64
        for t, c, n, s in bottleneck_setting:
            for i in range(n):
                stride = s if i == 0 else 1
                features.append(InvertedResidual(in_c, c, stride, t))
                in_c = c
        self.features = nn.Sequential(*features)

        # Conv2: 128→512, 1x1 (7→7)
        self.conv2 = nn.Sequential(
            nn.Conv2d(128, 512, 1, 1, 0, bias=False),
            nn.BatchNorm2d(512),
            nn.ReLU6(inplace=True),
        )

        # Global Depthwise Conv: 512, 7x7 (7→1)
        self.gdconv = GDConv(512, 7)

        # Linear projection: 512→128
        self.conv3 = nn.Conv2d(512, embedding_size, 1, 1, 0, bias=True)
        self.bn = nn.BatchNorm2d(embedding_size)
        self.flatten = nn.Flatten(1)

    def forward(self, x):
        x = self.conv1(x)
        x = self.dw_conv(x)
        x = self.features(x)
        x = self.conv2(x)
        x = self.gdconv(x)
        x = self.conv3(x)
        x = self.bn(x)
        x = self.flatten(x)  # [B, 128, 1, 1] → [B, 128]
        return x


# ──────────────────────────────────────────
# 2. 모델 초기화
# ──────────────────────────────────────────

print("🔧 MobileFaceNet 모델 초기화 중...")
model = MobileFaceNet(embedding_size=128)

# 사전학습 가중치 로드 (state_dict 방식 — RL/Fine-tuning 시 구조 수정 용이)
checkpoint = torch.load("mobilefacenet.pt", map_location="cpu")
model.load_state_dict(checkpoint)

model.eval()  # BatchNorm, Dropout 고정 — 필수
print("✅ 모델 준비 완료")

# ──────────────────────────────────────────
# 3. TorchScript 변환 (Core ML 변환의 전처리)
# ──────────────────────────────────────────

print("🔧 TorchScript 변환 중...")
dummy_input = torch.randn(1, 3, 112, 112)  # 배치=1, RGB, 112x112

with torch.no_grad():
    traced = torch.jit.trace(model, dummy_input)

print("✅ TorchScript 완료")

# ──────────────────────────────────────────
# 4. Core ML 변환 (Float16 양자화 포함)
# ──────────────────────────────────────────

print("🔧 Core ML 변환 중 (Float16 양자화 적용)...")

mlmodel = ct.convert(
    traced,
    inputs=[
        ct.ImageType(
            name="face_input",
            shape=(1, 3, 112, 112),
            color_layout=ct.colorlayout.RGB,
            # foamliu MobileFaceNet 학습 정규화: mean=0.5, std=0.5
            bias=[-1.0, -1.0, -1.0],
            scale=1.0 / (255.0 * 0.5),
        )
    ],
    outputs=[ct.TensorType(name="embedding_output")],
    # Windows에서는 NeuralNetwork 백엔드만 동작 (mlprogram/iOS16+은 macOS 전용)
    # 출력: .mlmodel — Xcode에서 .mlpackage와 동일하게 사용 가능
    convert_to="neuralnetwork",
    minimum_deployment_target=ct.target.iOS14,
    compute_units=ct.ComputeUnit.ALL,
)

print("✅ Core ML 변환 완료")

# ──────────────────────────────────────────
# 4-b. Float16 양자화 (NeuralNetwork 방식)
# ──────────────────────────────────────────

print("[*] Float16 양자화 적용 중...")
from coremltools.models.neural_network import quantization_utils
mlmodel = quantization_utils.quantize_weights(mlmodel, nbits=16)
print("[OK] Float16 양자화 완료 (용량 ~절반, 정확도 손실 미미)")

# ──────────────────────────────────────────
# 5. 메타데이터 추가
# ──────────────────────────────────────────

mlmodel.short_description = "MobileFaceNet Face Embedding Extractor (128-dim)"
mlmodel.author            = "Converted with coremltools"
mlmodel.version           = "1.0"
mlmodel.input_description["face_input"]        = "112x112 RGB face image (cropped, aligned)"
mlmodel.output_description["embedding_output"] = "128-dimensional L2-normalized face embedding"

# ──────────────────────────────────────────
# 6. 저장
# ──────────────────────────────────────────

# Windows에서는 .mlmodel 포맷으로 저장 (.mlpackage는 macOS 전용 라이브러리 필요)
# Xcode에서 .mlmodel도 .mlpackage와 동일하게 Swift 클래스 자동 생성됨
save_path = "MobileFaceNet.mlmodel"
ct.utils.save_spec(mlmodel.get_spec(), save_path)

size_mb = os.path.getsize(save_path) / 1024 / 1024

print("\n[완료]")
print("   파일: " + save_path)
print("   크기: {:.1f} MB".format(size_mb))
print("   임베딩 차원: 128")
print("\n[다음 단계]")
print("   1. MobileFaceNet.mlmodel 을 Mac으로 전송 (USB / Google Drive / 카카오톡)")
print("   2. Xcode 프로젝트에 드래그 앤 드롭")
print("   3. Swift에서 MobileFaceNet 클래스 자동 생성 확인")
print("   ⚠️  iOS 코드에서 임베딩 차원을 128로 맞출 것 (기존 512→128 변경)")
