# 02. 워크플로우 및 제어 로직 (Flow & Control)

> 에이전트가 "어떻게 생각하고", "어떻게 행동하며", "오류를 어떻게 처리하는가"를 정의하는 계층

---

## 2.1 추론 루프 (Reasoning Loop)

### ReAct (Reasoning + Acting) 패턴

LLM이 단순히 답변을 생성하는 것이 아니라, **생각(Thought) → 행동(Action) → 관찰(Observation)**을 반복하며 문제를 해결하는 방식입니다.

```
[사용자 입력]
      ↓
┌─────────────────────────────────┐
│  Thought: 어떤 도구가 필요한가?  │
│  Action:  tool_name(params)     │  ← LLM이 JSON으로 도구 호출 결정
│  Observation: 도구 실행 결과    │  ← 실제 함수 실행 후 결과 반환
└─────────────────────────────────┘
      ↓ (필요 시 루프 반복, 최대 N회)
[최종 응답 (Final Answer)]
```

#### ReAct 루프 구현 예시 (Python / LangChain)

```python
from langchain.agents import create_react_agent, AgentExecutor
from langchain_core.tools import tool

@tool
def get_attendance_record(employee_id: str) -> dict:
    """직원의 오늘 출퇴근 기록을 조회합니다."""
    return db.query(f"SELECT * FROM attendance WHERE emp_id='{employee_id}'")

agent = create_react_agent(llm=llm, tools=[get_attendance_record], prompt=react_prompt)
executor = AgentExecutor(agent=agent, tools=[get_attendance_record], max_iterations=5)
result = executor.invoke({"input": "홍길동의 오늘 출근 시간은?"})
```

---

### Chain of Thought (CoT) 패턴

복잡한 다단계 추론이 필요할 때, LLM에게 **중간 추론 과정을 명시적으로 출력**하도록 유도합니다.

| CoT 유형 | 프롬프트 트리거 | 적합한 상황 |
|---|---|---|
| **Zero-shot CoT** | `"단계별로 생각해 보세요."` | 빠른 구현, 일반 질의 |
| **Few-shot CoT** | 예시 3~5개 포함 | 정형화된 업무 (급여 계산 등) |
| **Self-consistency CoT** | 동일 질의 N회 실행 후 다수결 | 고정확도 요구 시 |
| **Tree of Thought (ToT)** | 분기 탐색 후 최적 경로 선택 | 복잡한 의사결정 트리 |

```python
# Zero-shot CoT 적용 예시
prompt = """
직원 A의 이번 달 초과근무를 계산하세요.
규정: 월 기본 시간 = 160시간, 초과 시 1.5배 지급.
출근 기록: [데이터]

단계별로 생각하세요:
1. 총 근무 시간 합산
2. 기본 시간 차감
3. 초과 시간에 1.5 적용
"""
```

---

## 2.2 상태 관리 (State Management)

### 대화 컨텍스트 윈도우 전략

LLM의 컨텍스트 윈도우는 유한하므로(GPT-4: 128K tokens), 긴 대화를 효율적으로 관리해야 합니다.

```
[전체 대화 이력]
      ↓
┌──────────────────────────────────────┐
│  Strategy 1: Sliding Window          │
│  - 최근 N개 메시지만 유지 (N=10~20)  │
│  - 단순, 구현 쉬움                   │
│  - 오래된 맥락 소실 위험             │
├──────────────────────────────────────┤
│  Strategy 2: Summary + Recent        │
│  - 오래된 대화 → LLM으로 요약        │
│  - 요약본 + 최근 대화 조합           │
│  - 맥락 유지율 높음                  │
├──────────────────────────────────────┤
│  Strategy 3: Vector Memory           │
│  - 전체 대화를 벡터 DB에 저장        │
│  - 현재 질의와 유사한 과거 대화 검색  │
│  - 장기 사용자 이력 관리에 최적      │
└──────────────────────────────────────┘
```

### 세션 관리 구조

```python
class SessionManager:
    def __init__(self):
        self.store = {}  # session_id → MessageHistory

    def get_session(self, session_id: str) -> list:
        if session_id not in self.store:
            self.store[session_id] = []
        return self.store[session_id]

    def add_message(self, session_id: str, role: str, content: str):
        history = self.get_session(session_id)
        history.append({"role": role, "content": content})
        # 슬라이딩 윈도우: 최근 20개만 유지
        if len(history) > 20:
            self.store[session_id] = history[-20:]
```

### 상태 저장 백엔드 선택

| 백엔드 | 저장 방식 | TTL 지원 | 분산 지원 | 추천 용도 |
|---|---|---|---|---|
| **In-Memory (dict)** | 프로세스 메모리 | 수동 | X | 개발/테스트 |
| **Redis** | Key-Value | O (자동 만료) | O | 프로덕션 세션 |
| **PostgreSQL** | RDB | 수동 | O | 영구 대화 이력 |
| **DynamoDB** | NoSQL | O (TTL) | O | 서버리스 환경 |

---

## 2.3 오류 처리 (Error Handling)

### 할루시네이션(Hallucination) 방지 전략

```
[방지 레이어 1: 프롬프트 수준]
→ "모르면 모른다고 하세요" 명시
→ "답변 근거를 문서에서 인용하세요" 명시
→ "추측하지 마세요" 명시

[방지 레이어 2: RAG 수준]
→ 검색 신뢰도 임계값 설정 (similarity score < 0.75 → 검색 실패 처리)
→ 출처(Source) 함께 반환하여 사용자 검증 가능하게 제공

[방지 레이어 3: 후처리(Post-processing) 수준]
→ 응답에 포함된 수치/날짜 → DB 실제값과 교차 검증
→ Groundedness 검사: LLM-as-a-Judge 패턴으로 자기 검증
```

### 예외 상황 처리 플로우

```python
async def safe_agent_invoke(query: str, session_id: str) -> dict:
    try:
        result = await agent_executor.ainvoke({"input": query})
        return {"status": "success", "data": result["output"]}

    except ToolExecutionError as e:
        # 도구 실행 실패 → 재시도 또는 대체 도구 사용
        logger.error(f"Tool failed: {e}")
        return {"status": "tool_error", "message": "외부 시스템 연결에 실패했습니다."}

    except ContextWindowExceededError:
        # 컨텍스트 초과 → 요약 후 재시도
        summarize_session(session_id)
        return await safe_agent_invoke(query, session_id)

    except MaxIterationsExceeded:
        # 루프 초과 → 강제 종료 후 부분 답변 반환
        return {"status": "timeout", "message": "처리 시간이 초과되었습니다. 질의를 단순화해 주세요."}

    except Exception as e:
        logger.critical(f"Unexpected error: {e}")
        return {"status": "error", "message": "내부 오류가 발생했습니다."}
```

### 재시도(Retry) 전략

| 오류 유형 | 재시도 여부 | 전략 |
|---|---|---|
| **Rate Limit (429)** | O | Exponential Backoff (1s → 2s → 4s) |
| **Network Timeout** | O | 최대 3회, jitter 추가 |
| **Tool Execution Error** | 조건부 | 대체 도구 존재 시 fallback |
| **Context Window Exceeded** | O | 세션 요약 후 1회 재시도 |
| **Invalid JSON Output** | O | Output Parser 재파싱, 최대 2회 |
| **Hallucination 감지** | O | 재질의 또는 "확인 불가" 반환 |
