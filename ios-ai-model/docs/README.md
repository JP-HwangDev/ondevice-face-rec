# AI 에이전트 아키텍처 & iOS 얼굴인식 시스템 문서

> 이 폴더는 AI 에이전트 설계 원칙과 사내 그룹웨어 연동형 iOS 온디바이스 얼굴인식 시스템 구현 가이드를 담고 있습니다.

---

## 문서 목록

### Part 1: AI 에이전트 아키텍처

| 문서 | 내용 |
|---|---|
| [01_structured_context.md](./01_structured_context.md) | 페르소나 정의, RAG/벡터 DB, 제약 조건 및 윤리 가이드라인 |
| [02_flow_and_control.md](./02_flow_and_control.md) | ReAct/CoT 추론 루프, 세션 관리, 할루시네이션 방지 |
| [03_tech_stack_and_tools.md](./03_tech_stack_and_tools.md) | 오케스트레이션 프레임워크 비교, LLM 선택 기준, Function Calling |
| [04_requirements_and_optimization.md](./04_requirements_and_optimization.md) | 평가 지표(RAGAS), 단기/장기 메모리, 멀티 에이전트 스케일링 |

### Part 2: iOS 얼굴인식 시스템

| 문서 | 내용 |
|---|---|
| [05_ios_face_recognition_overview.md](./05_ios_face_recognition_overview.md) | 시스템 목표, 전체 아키텍처, 핵심 개념(임베딩), 보안 전략 |
| [06_ios_tech_stack.md](./06_ios_tech_stack.md) | AVFoundation, Vision, Core ML, GRDB, Keychain 코드 레벨 구현 |
| [07_model_conversion_and_deployment.md](./07_model_conversion_and_deployment.md) | Windows → Core ML 변환, 양자화, Xcode 통합, 배포 체크리스트 |

---

## 빠른 시작

### AI 에이전트를 처음 설계하는 경우
1. `01_structured_context.md` → 에이전트 정체성 정의
2. `02_flow_and_control.md` → ReAct 추론 루프 구현
3. `03_tech_stack_and_tools.md` → 프레임워크/모델 선택
4. `04_requirements_and_optimization.md` → 성능 측정 및 스케일링

### iOS 얼굴인식 앱을 처음 개발하는 경우
1. `05_ios_face_recognition_overview.md` → 전체 구조 파악
2. `07_model_conversion_and_deployment.md` → Windows에서 모델 변환 먼저 수행
3. `06_ios_tech_stack.md` → Swift 코드 구현

---

## 기술 스택 요약

```
[AI 에이전트]                    [iOS 얼굴인식]
─────────────────────            ──────────────────────
LangChain / LangGraph            AVFoundation (카메라)
GPT-4o / Claude 3.5              Vision Framework (탐지)
Pinecone / Qdrant (RAG)          Core ML + MobileFaceNet
Redis (세션)                     GRDB.swift (벡터 DB)
RAGAS (평가)                     Keychain (보안 저장)
CrewAI (멀티 에이전트)            Accelerate (벡터 연산)
```
