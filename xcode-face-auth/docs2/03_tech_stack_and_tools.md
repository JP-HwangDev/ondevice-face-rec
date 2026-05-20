# 03. 기술 스택 및 도구 (Tech Stack & Tools)

> 에이전트를 "어떤 도구로 조립하고", "어떤 모델을 선택하며", "외부 세계와 어떻게 연결하는가"를 정의하는 계층

---

## 3.1 오케스트레이션 프레임워크 (Orchestration)

에이전트의 추론 루프, 도구 호출, 메모리 관리를 통합하는 **메인 컨트롤러** 역할을 합니다.

### 프레임워크 비교표

| 프레임워크 | 주요 특징 | 러닝 커브 | 멀티 에이전트 | 최적 사용 시나리오 |
|---|---|---|---|---|
| **LangChain** | 생태계 최대, 도구 풍부 | 중간 | O (LangGraph) | 범용 에이전트, RAG 파이프라인 |
| **LangGraph** | 상태 그래프 기반, 사이클 지원 | 높음 | O (네이티브) | 복잡한 분기 워크플로우 |
| **CrewAI** | 역할 기반 팀 에이전트 | 낮음 | O (네이티브) | 역할 분담형 멀티 에이전트 |
| **AutoGPT** | 자율 목표 달성 에이전트 | 낮음 | 제한적 | 장기 자율 작업 |
| **Semantic Kernel** | Microsoft 생태계, C# 지원 | 중간 | O | Azure/M365 연동 기업 환경 |
| **Haystack** | NLP/RAG 특화 파이프라인 | 중간 | 제한적 | 문서 검색, Q&A 시스템 |

### LangGraph 상태 그래프 예시

```python
from langgraph.graph import StateGraph, END
from typing import TypedDict, Annotated

class AgentState(TypedDict):
    query: str
    retrieved_context: list
    tool_results: dict
    final_answer: str
    iteration_count: int

def build_graph():
    graph = StateGraph(AgentState)

    graph.add_node("retriever", retrieve_context)
    graph.add_node("reasoner", run_llm_reasoning)
    graph.add_node("tool_caller", execute_tools)
    graph.add_node("responder", generate_final_response)

    graph.set_entry_point("retriever")
    graph.add_edge("retriever", "reasoner")
    graph.add_conditional_edges(
        "reasoner",
        lambda state: "tool_caller" if state["needs_tool"] else "responder",
        {"tool_caller": "tool_caller", "responder": "responder"}
    )
    graph.add_edge("tool_caller", "reasoner")
    graph.add_edge("responder", END)

    return graph.compile()
```

---

## 3.2 모델 선택 기준 (Model Selection)

### LLM 성능/비용 매트릭스

| 모델 | 제공사 | 컨텍스트 | 강점 | 비용(입력/1M tokens) | 추천 용도 |
|---|---|---|---|---|---|
| **GPT-4o** | OpenAI | 128K | 멀티모달, 범용 추론 | $5.00 | 복잡한 분석, 이미지 처리 |
| **GPT-4o-mini** | OpenAI | 128K | 비용 효율 | $0.15 | 고빈도 경량 에이전트 |
| **Claude 3.5 Sonnet** | Anthropic | 200K | 긴 문서, 코드 | $3.00 | 코드 생성, 긴 문서 분석 |
| **Claude 3 Haiku** | Anthropic | 200K | 초고속, 저비용 | $0.25 | 실시간 응답, 분류 작업 |
| **Llama 3.1 70B** | Meta (OSS) | 128K | 오픈소스, 자체 호스팅 | 자체 인프라 비용 | 보안 요구 온프레미스 환경 |
| **Gemini 1.5 Pro** | Google | 1M | 초장문 컨텍스트 | $3.50 | 대용량 문서 전체 처리 |

### 모델 선택 의사결정 트리

```
질문 1: 온프레미스/폐쇄망 환경인가?
  YES → Llama 3.1 (Ollama 로컬 배포) 또는 Azure OpenAI (Private Endpoint)
  NO  → 클라우드 API 계속 평가

질문 2: 멀티모달(이미지/음성) 처리가 필요한가?
  YES → GPT-4o 또는 Gemini 1.5 Pro
  NO  → 텍스트 전용 모델 계속 평가

질문 3: 응답 지연(Latency)이 500ms 이하여야 하는가?
  YES → Claude 3 Haiku 또는 GPT-4o-mini
  NO  → 고성능 모델 선택 가능

질문 4: 컨텍스트가 50K tokens 초과인가?
  YES → Claude 3.5 Sonnet (200K) 또는 Gemini 1.5 Pro (1M)
  NO  → GPT-4o (128K) 또는 Claude 3 Haiku
```

### 하이브리드 모델 라우팅 전략

```python
def route_to_model(task_type: str, complexity: float) -> str:
    """
    단순 분류/추출 → 경량 모델
    복잡한 추론/생성 → 고성능 모델
    """
    if task_type in ["classification", "extraction"] or complexity < 0.3:
        return "claude-3-haiku-20240307"   # 빠름, 저렴
    elif task_type == "code_generation" or complexity > 0.8:
        return "claude-sonnet-4-5-20250929"  # 고성능
    else:
        return "gpt-4o-mini"               # 기본값
```

---

## 3.3 함수 호출 (Function Calling)

LLM이 외부 API, DB, 내부 시스템과 상호작용하기 위한 **도구 사용(Tool Use)** 메커니즘입니다.

### Tool Use 동작 원리

```
[사용자]: "홍길동 오늘 출근했어?"
      ↓
[LLM 판단]: get_attendance_record 함수 호출 필요
      ↓
[JSON 출력]:
{
  "tool_name": "get_attendance_record",
  "parameters": {
    "employee_name": "홍길동",
    "date": "2026-02-11"
  }
}
      ↓
[애플리케이션]: 실제 DB 쿼리 실행
      ↓
[결과 반환]: {"check_in": "09:02", "check_out": null}
      ↓
[LLM 최종 응답]: "홍길동 님은 오전 9시 2분에 출근했으며, 아직 퇴근 기록이 없습니다."
```

### Tool 정의 스키마 (OpenAI 형식)

```python
tools = [
    {
        "type": "function",
        "function": {
            "name": "get_attendance_record",
            "description": "특정 직원의 출퇴근 기록을 조회합니다.",
            "parameters": {
                "type": "object",
                "properties": {
                    "employee_id": {
                        "type": "string",
                        "description": "직원 ID (예: EMP001)"
                    },
                    "date": {
                        "type": "string",
                        "description": "조회 날짜 (YYYY-MM-DD 형식)"
                    }
                },
                "required": ["employee_id", "date"]
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "register_face_embedding",
            "description": "새 직원의 얼굴 임베딩 벡터를 시스템에 등록합니다.",
            "parameters": {
                "type": "object",
                "properties": {
                    "employee_id": {"type": "string"},
                    "embedding_vector": {
                        "type": "array",
                        "items": {"type": "number"},
                        "description": "512차원 얼굴 특징 벡터"
                    }
                },
                "required": ["employee_id", "embedding_vector"]
            }
        }
    }
]
```

### 도구 카테고리 및 보안 등급

| 도구 카테고리 | 예시 | 읽기/쓰기 | 승인 필요 |
|---|---|---|---|
| **조회 (Read-only)** | 출퇴근 기록 조회, 직원 정보 검색 | 읽기 | 불필요 |
| **등록/수정 (Write)** | 얼굴 임베딩 등록, 출석 기록 수정 | 쓰기 | 권장 |
| **삭제 (Delete)** | 직원 데이터 삭제 | 쓰기 | 필수 (Human-in-the-loop) |
| **외부 연동 (External)** | 그룹웨어 API, 슬랙 알림 | 양방향 | 조건부 |

### Parallel Tool Calling

```python
# 여러 도구를 동시에 호출하여 지연 시간 단축
response = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": "김철수와 박영희의 출근 현황 비교해줘"}],
    tools=tools,
    tool_choice="auto",
    parallel_tool_calls=True  # 두 직원 동시 조회
)
```
