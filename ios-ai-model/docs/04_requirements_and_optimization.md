# 04. 에이전트 최적화 요소 (Requirements & Optimization)

> 에이전트를 "어떻게 측정하고", "어떻게 기억하며", "어떻게 확장하는가"를 정의하는 계층

---

## 4.1 평가 지표 (Evaluation)

에이전트의 성능을 정량적으로 측정하기 위한 메트릭 체계입니다.

### 핵심 평가 지표 (KPI)

| 카테고리 | 지표 | 계산식 | 목표값 |
|---|---|---|---|
| **정확도** | Precision | TP / (TP + FP) | ≥ 0.90 |
| **정확도** | Recall | TP / (TP + FN) | ≥ 0.85 |
| **정확도** | F1-Score | 2 × (P × R) / (P + R) | ≥ 0.87 |
| **응답 품질** | Answer Relevance | LLM-as-Judge 점수 (1~5) | ≥ 4.0 |
| **응답 품질** | Faithfulness | 근거 문서와의 일치율 | ≥ 0.90 |
| **응답 품질** | Context Recall | 필요 정보 검색 성공률 | ≥ 0.85 |
| **성능** | End-to-End Latency | 질의 → 응답 완료 시간 | ≤ 3,000ms |
| **성능** | Time to First Token | 첫 토큰 출력까지 시간 | ≤ 800ms |
| **비용** | Cost per Query | 쿼리당 API 비용 | 목표 예산 내 |

### RAGAS 기반 RAG 평가 파이프라인

```python
from ragas import evaluate
from ragas.metrics import (
    answer_relevancy,
    faithfulness,
    context_recall,
    context_precision
)

# 평가 데이터셋 구성
eval_dataset = {
    "question": ["홍길동의 이번 달 지각 횟수는?"],
    "answer": ["3회입니다."],
    "contexts": [["출퇴근 DB 조회 결과: 3/1 09:15, 3/5 09:22, ..."]],
    "ground_truth": ["3회"]
}

result = evaluate(
    dataset=eval_dataset,
    metrics=[answer_relevancy, faithfulness, context_recall, context_precision]
)
print(result)
# {'answer_relevancy': 0.94, 'faithfulness': 0.97, 'context_recall': 0.89, ...}
```

### LLM-as-a-Judge 자동 평가

```python
JUDGE_PROMPT = """
다음 AI 응답을 5점 척도로 평가하세요.

질문: {question}
AI 응답: {answer}
참조 문서: {context}

평가 기준:
1. 관련성 (1-5): 질문과 응답의 연관도
2. 정확성 (1-5): 참조 문서와의 일치도
3. 완결성 (1-5): 답변의 완성도

JSON 형식으로 출력: {"relevance": X, "accuracy": X, "completeness": X}
"""
```

---

## 4.2 메모리 (Memory)

에이전트의 기억 체계는 인간의 기억 구조를 모방하여 **단기(Short-term)**와 **장기(Long-term)**로 구분됩니다.

### 메모리 유형 비교

| 유형 | 범위 | 저장 위치 | 휘발성 | 주요 용도 |
|---|---|---|---|---|
| **Sensory (버퍼)** | 현재 입력 | LLM 컨텍스트 | 즉시 사라짐 | 현재 메시지 처리 |
| **Short-term** | 현재 세션 | In-memory / Redis | 세션 종료 시 | 대화 이력, 임시 계획 |
| **Long-term (Episodic)** | 과거 대화 이력 | 벡터 DB | 영구 | 개인화, 이전 요청 참조 |
| **Long-term (Semantic)** | 지식/사실 | 벡터 DB / RDB | 영구 | 도메인 지식, FAQ |
| **Procedural** | 학습된 행동 패턴 | 시스템 프롬프트 / Fine-tuning | 영구 | 반복 업무 자동화 |

### 메모리 구현 아키텍처

```
[세션 시작]
      ↓
[Short-term Memory 로드]
├─ 최근 N개 메시지 (Redis)
└─ 현재 세션 태스크 상태

      ↓ 사용자 입력 발생 시
[Long-term Memory 검색]
├─ 임베딩 생성 (사용자 입력)
└─ 유사 과거 대화/지식 Top-K 검색 (벡터 DB)

      ↓ 응답 생성 후
[메모리 업데이트]
├─ Short-term: 새 메시지 추가
├─ Long-term: 중요 정보 추출 → 벡터 DB 저장
└─ 요약: 일정 길이 초과 시 자동 요약 생성
```

### MemGPT 스타일 계층 메모리 구현

```python
class AgentMemory:
    def __init__(self, session_id: str):
        self.session_id = session_id
        self.working_memory = []          # 현재 대화 (in-memory)
        self.summary_memory = ""          # 요약된 이전 대화
        self.vector_store = ChromaDB()    # 장기 메모리

    def add_to_working(self, role: str, content: str):
        self.working_memory.append({"role": role, "content": content})
        # 임계값 초과 시 자동 요약
        if len(self.working_memory) > 20:
            self._compress_to_summary()

    def _compress_to_summary(self):
        # 오래된 대화를 LLM으로 요약
        old_messages = self.working_memory[:-10]
        summary = llm.summarize(old_messages)
        self.summary_memory += f"\n[요약] {summary}"
        self.working_memory = self.working_memory[-10:]

        # 중요 정보는 장기 메모리에 저장
        self.vector_store.add(
            texts=[summary],
            metadatas=[{"session_id": self.session_id, "type": "episodic"}]
        )

    def retrieve_relevant_memory(self, query: str) -> list:
        # 현재 질의와 관련된 과거 기억 검색
        return self.vector_store.similarity_search(query, k=3)
```

---

## 4.3 스케일링 (Scaling)

### 멀티 에이전트 오케스트레이션 패턴

#### 패턴 1: Supervisor (관리자-작업자)

```
[Supervisor Agent]
├─ 사용자 요청 분석 및 작업 분배
├─ [Worker Agent A]: 출퇴근 데이터 처리
├─ [Worker Agent B]: 보고서 생성
└─ [Worker Agent C]: 알림/메시지 발송
      ↓
[Supervisor Agent]: 결과 취합 및 최종 응답
```

```python
# CrewAI 멀티 에이전트 구성 예시
from crewai import Agent, Task, Crew

attendance_analyst = Agent(
    role="출퇴근 데이터 분석가",
    goal="출퇴근 데이터를 정확하게 분석하고 이상 패턴을 탐지",
    tools=[attendance_db_tool, calendar_tool],
    llm="claude-sonnet-4-5-20250929"
)

report_writer = Agent(
    role="보고서 작성 전문가",
    goal="분석 결과를 명확한 보고서로 작성",
    tools=[document_writer_tool],
    llm="gpt-4o-mini"  # 저비용 모델로 비용 최적화
)

crew = Crew(
    agents=[attendance_analyst, report_writer],
    tasks=[analysis_task, report_task],
    process="sequential"  # sequential | hierarchical
)
```

#### 패턴 2: 병렬 에이전트 (Parallel Agents)

```
[Orchestrator]
      ↓ 동시 실행
┌─────────────────────────────┐
│ [Agent A] 실시간 얼굴 인식  │
│ [Agent B] 출결 DB 조회      │
│ [Agent C] 이상 패턴 탐지    │
└─────────────────────────────┘
      ↓ 결과 병합 (Reduce)
[최종 응답]
```

```python
import asyncio

async def parallel_agent_execution(employee_id: str):
    results = await asyncio.gather(
        face_recognition_agent.run(employee_id),
        attendance_db_agent.run(employee_id),
        anomaly_detection_agent.run(employee_id),
        return_exceptions=True
    )
    return merge_results(results)
```

### 확장성 아키텍처 설계

```
[Load Balancer]
      ↓
[Agent Gateway] ← 인증, 라우팅, 속도 제한
      ↓
[Agent Pool (수평 확장)]
├─ Agent Instance 1
├─ Agent Instance 2
└─ Agent Instance N
      ↓
[공유 인프라]
├─ Redis (세션/캐시)
├─ Vector DB (메모리)
├─ Message Queue (Kafka/RabbitMQ)
└─ Monitoring (Langfuse / LangSmith)
```

### 모니터링 및 관찰 가능성 (Observability)

| 도구 | 역할 | 핵심 기능 |
|---|---|---|
| **LangSmith** | LangChain 전용 트레이싱 | 프롬프트 이력, 토큰 사용량, 오류 추적 |
| **Langfuse** | 오픈소스 LLM 관찰 | 비용 분석, A/B 테스트, 품질 평가 |
| **Weights & Biases** | ML 실험 추적 | 모델 성능 비교, 파인튜닝 모니터링 |
| **Prometheus + Grafana** | 인프라 메트릭 | Latency, Throughput, Error Rate |

```python
# Langfuse 트레이싱 통합 예시
from langfuse.decorators import observe, langfuse_context

@observe()
async def process_attendance_query(query: str, employee_id: str):
    langfuse_context.update_current_observation(
        metadata={"employee_id": employee_id},
        tags=["attendance", "production"]
    )
    result = await agent_executor.ainvoke({"input": query})
    langfuse_context.update_current_observation(
        output=result["output"],
        usage={"total_tokens": result.get("token_usage", 0)}
    )
    return result
```
