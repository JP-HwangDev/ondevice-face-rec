# 데이터 구조

## GRDB 스키마

### User 테이블
얼굴 인식을 위한 등록 사용자 정보

```swift
struct User: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?              // 자동 증가 Primary Key
    var name: String            // 사용자 이름
    var faceVector: Data        // 얼굴 특징 벡터 (직렬화된 [Float])
    var registeredAt: Date      // 등록일시
    var department: String?     // 부서 (선택)
    
    static let databaseTableName = "users"
}
```

### SQL 테이블 정의

```sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    faceVector BLOB NOT NULL,      -- 벡터 데이터 (128~512 Float 배열)
    registeredAt DATETIME NOT NULL,
    department TEXT
);

CREATE INDEX idx_name ON users(name);
```

## 벡터 데이터 형식

### 얼굴 특징 벡터
- **차원**: 128 또는 512 (MobileFaceNet 모델에 따라 다름)
- **타입**: `[Float]` → `Data`로 직렬화
- **저장**: BLOB 타입으로 SQLite에 저장

### 벡터 직렬화/역직렬화

```swift
// Float 배열 → Data
let vector: [Float] = [...] // 128 또는 512 차원
let data = vector.withUnsafeBytes { Data($0) }

// Data → Float 배열
let vector = data.withUnsafeBytes {
    Array(UnsafeBufferPointer<Float>(
        start: $0.baseAddress?.assumingMemoryBound(to: Float.self),
        count: data.count / MemoryLayout<Float>.size
    ))
}
```

## 유사도 계산

### Cosine Similarity (코사인 유사도)

```swift
import Accelerate

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
    vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
    
    return dot / (sqrt(normA) * sqrt(normB))
}
```

### 매칭 임계값
- **동일인 판정**: similarity ≥ 0.6~0.7
- **타인 판정**: similarity < 0.6
- 프로젝트 특성에 따라 조정 가능

## 출석 기록 (추후 확장)

### AttendanceLog 테이블 (선택사항)

```swift
struct AttendanceLog: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var userId: Int64           // User 테이블 외래키
    var timestamp: Date         // 출석 시각
    var confidence: Float       // 인식 신뢰도 (0.0~1.0)
    
    static let databaseTableName = "attendance_logs"
}
```

## 데이터 흐름

1. **등록**: 카메라 → Vision → Core ML → 벡터 추출 → GRDB 저장
2. **인식**: 카메라 → Vision → Core ML → 벡터 추출 → Accelerate 비교 → 매칭
3. **출석**: 매칭 성공 → 그룹웨어 API 호출 (또는 로컬 로그 저장)
