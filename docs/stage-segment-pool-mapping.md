# Stage, segment và pool mapping — hướng dẫn upstream

## 1. Mục đích và phạm vi

Tài liệu này ghi lại quy tắc phân Stage từ `DEFAULT.dbo.CUSTOMER_ODR_LRA_IRB` và mapping segment sang pool theo cấu hình người dùng cung cấp. Đây là logic chuẩn hóa dữ liệu **upstream** trước khi nạp vào hợp đồng đầu vào của ECL engine; nó không thay thế hay sửa công thức tính ECL trong engine.

Ví dụ dưới đây dùng `PROCESS_DATE = '2026-09-30'` để minh họa. Khi chạy thật, ngày xử lý phải lấy từ ngày chốt dữ liệu của run, không hard-code ngày mẫu.

## 2. Quy tắc xác định Stage từ bucket

| Bucket nguồn | Stage | Ý nghĩa |
|---|---:|---|
| `b1: mob <6 & dpd 0-30` | 1 | MOB dưới 6 và DPD 0–30 |
| `b2: mob >=6 & dpd 0-30` | 1 | MOB từ 6 trở lên và DPD 0–30 |
| `b3: dpd 31-60` | 2 | DPD 31–60 |
| `b4: dpd 61-90` | 2 | DPD 61–90 |
| `b5: dpd >90` | 3 | DPD trên 90 |
| Giá trị khác hoặc NULL | NULL / lỗi dữ liệu | Không tự động gán Stage |

Mapping này là business rule được cung cấp cho repo, không phải kết luận rằng bucket đơn lẻ bao phủ toàn bộ yêu cầu SICR theo IFRS 9. Nếu ngân hàng có override SICR, forbearance, qualitative indicators hoặc quy tắc khác, cần kết hợp theo chính sách đã phê duyệt trước khi nạp snapshot.

## 3. Mapping segment → pool

| POOL_ID | POOL_NAME | CUSTOMER_TYPE_MODEL | SEGMENT |
|---:|---|---|---|
| 100 | `RETAIL_LN_AUTO` | `RETAIL` | `Autoloan` |
| 101 | `RETAIL_LN_CONS_SEC` | `RETAIL` | `Consumer lending - secured` |
| 102 | `RETAIL_LN_CONS_UNSEC` | `RETAIL` | `Consumer lending - unsecured` |
| 103 | `RETAIL_LN_MORTGAGE` | `RETAIL` | `Mortgage` |
| 104 | `RETAIL_LN_OTHERS` | `RETAIL` | `Others` |
| 105 | `RETAIL_CARD` | `RETAIL` | `CC` |
| 106 | `RETAIL_OVERDRAFT` | `RETAIL` | `OD` |
| 200 | `CORP_LARGE_LOAN` | `CORP_L` | `Large` |
| 201 | `CORP_MEDIUM_LOAN` | `CORP_M` | `Medium` |
| 202 | `CORP_SMALL_LOAN` | `CORP_S` | `Small` |

Lưu ý: query nguồn ở mục 4 chỉ lọc 7 segment Retail. Các pool Corporate (200–202) là cấu hình mapping riêng; query retail hiện tại không trả các segment Large/Medium/Small. Cần xác nhận nguồn upstream và mapping customer type của Corporate trước khi dùng chung trong một batch.

## 4. SQL tham khảo: tạo account snapshot source

SQL dưới đây mô tả mapping; chỉ chạy khi đã xác nhận database/schema nguồn và quyền truy cập. Nó không ghi trực tiếp vào bảng canonical của engine vì cần ánh xạ thêm `ACCOUNT_ID`, `PRODUCT_TYPE`, `MATURITY_DATE`, `VERSION_ID` và `RUN_ID` từ các nguồn được phê duyệt.

```sql
DECLARE @PROCESS_DATE date = '2026-09-30';

WITH SegmentPool AS (
    SELECT *
    FROM (VALUES
        (100, 'RETAIL_LN_AUTO',       'RETAIL', 'Autoloan'),
        (101, 'RETAIL_LN_CONS_SEC',   'RETAIL', 'Consumer lending - secured'),
        (102, 'RETAIL_LN_CONS_UNSEC', 'RETAIL', 'Consumer lending - unsecured'),
        (103, 'RETAIL_LN_MORTGAGE',   'RETAIL', 'Mortgage'),
        (104, 'RETAIL_LN_OTHERS',     'RETAIL', 'Others'),
        (105, 'RETAIL_CARD',          'RETAIL', 'CC'),
        (106, 'RETAIL_OVERDRAFT',     'RETAIL', 'OD'),
        (200, 'CORP_LARGE_LOAN',      'CORP_L', 'Large'),
        (201, 'CORP_MEDIUM_LOAN',     'CORP_M', 'Medium'),
        (202, 'CORP_SMALL_LOAN',      'CORP_S', 'Small')
    ) AS v(POOL_ID, POOL_NAME, CUSTOMER_TYPE_MODEL, SEGMENT)
),
StageMap AS (
    SELECT *
    FROM (VALUES
        ('b1: mob <6 & dpd 0-30', 1),
        ('b2: mob >=6 & dpd 0-30', 1),
        ('b3: dpd 31-60', 2),
        ('b4: dpd 61-90', 2),
        ('b5: dpd >90', 3)
    ) AS v(BUCKET, STAGE)
)
SELECT
    src.process_date,
    src.customer_id,
    src.segment_odr_lv1 AS segment,
    src.bucket,
    sm.STAGE,
    sp.POOL_ID,
    sp.POOL_NAME,
    sp.CUSTOMER_TYPE_MODEL
FROM [DEFAULT].[dbo].[CUSTOMER_ODR_LRA_IRB] AS src
LEFT JOIN StageMap AS sm
    ON sm.BUCKET = src.bucket
LEFT JOIN SegmentPool AS sp
    ON sp.SEGMENT = src.segment_odr_lv1
WHERE src.process_date = @PROCESS_DATE
  AND src.segment_odr_lv1 IN (
      'Autoloan',
      'Consumer lending - secured',
      'Consumer lending - unsecured',
      'Mortgage',
      'Others',
      'CC',
      'OD'
  );
```

Dùng `LEFT JOIN` để các dòng chưa mapping vẫn xuất hiện trong kết quả kiểm tra. Trước khi nạp chính thức, cần chặn run nếu Stage hoặc pool chưa mapping thay vì loại bỏ âm thầm những dòng này.

## 5. Kiểm tra chất lượng trước khi nạp

Chạy truy vấn tương tự dưới đây trên dữ liệu nguồn để phát hiện bucket hoặc segment chưa được cấu hình:

```sql
DECLARE @PROCESS_DATE date = '2026-09-30';

SELECT
    process_date,
    segment_odr_lv1 AS segment,
    bucket,
    COUNT_BIG(*) AS row_count
FROM [DEFAULT].[dbo].[CUSTOMER_ODR_LRA_IRB]
WHERE process_date = @PROCESS_DATE
GROUP BY process_date, segment_odr_lv1, bucket
ORDER BY segment, bucket;
```

Checklist tối thiểu:
- Mỗi dòng tài khoản có đúng một Stage hợp lệ trong (1, 2, 3).
- Mỗi segment retail được chọn map đến đúng một `POOL_ID`.
- Không có `customer_id` NULL hoặc trùng khóa ở grain đầu vào mà quy trình upstream phê duyệt.
- `PROCESS_DATE` đồng nhất với ngày của `ecl_core.RunControl`.
- Snapshot có đủ `ACCOUNT_ID`, `PRODUCT_TYPE`, `MATURITY_DATE`, `RUN_ID`, `VERSION_ID`; quy tắc chuyển `CUSTOMER_ID` thành `ACCOUNT_ID` phải được xác nhận theo nguồn dữ liệu, không mặc định hai khóa này tương đương.
- Kết quả Stage/pool mapping được lưu hoặc truy vết theo run để có thể tái lập và giải trình.

## 6. Map vào hợp đồng canonical

Khi chuẩn hóa upstream, các trường tối thiểu liên quan là:

| Canonical `ecl_stg.AccountSnapshot` | Nguồn/mapping |
|---|---|
| `PROCESS_DATE` | `src.process_date`, phải bằng ngày của run |
| `CUSTOMER_ID` | `src.customer_id` |
| `STAGE` | `StageMap` theo `src.bucket` |
| `POOL_ID` | `SegmentPool.POOL_ID` |
| `PRODUCT_TYPE` | Cần mapping riêng từ segment sang mã `ecl_cfg.ProductType`; không suy đoán chỉ từ `POOL_NAME` |
| `ACCOUNT_ID` | Khóa tài khoản theo nguồn đã phê duyệt; `CUSTOMER_ID` chỉ dùng thay thế nếu business xác nhận đúng grain |
| `MATURITY_DATE` | Nguồn hợp đồng/khoản vay đã phê duyệt |
| `RUN_ID`, `VERSION_ID`, `IS_ACTIVE` | Do quy trình điều phối và kiểm soát phiên bản upstream cấp |

Engine vẫn chịu trách nhiệm xác thực hợp đồng canonical, tính toán ECL, đối soát và xuất bản. SQL tham khảo trong tài liệu này chỉ chuẩn hóa Stage và pool; nó chưa phải migration triển khai nguồn production.

## 7. Điểm cần xác nhận trước khi triển khai

1. Nguồn `CUSTOMER_ODR_LRA_IRB` có một dòng mỗi customer hay mỗi account? Nếu là customer-level, cần xác định cách chọn Stage/pool khi khách hàng có nhiều khoản vay.
2. Có cần lọc Corporate từ một nguồn/segment khác hay không? Query retail mẫu hiện tại không gồm `Large`, `Medium`, `Small`.
3. Mapping `SEGMENT` sang `PRODUCT_TYPE` nào được phê duyệt, đặc biệt với `Others`, `CC`, `OD`.
4. `bucket` có phản ánh đầy đủ Stage/SICR theo chính sách IFRS 9 hiện hành không, và quy tắc xử lý bucket NULL/không biết là chặn run hay ngoại lệ được phê duyệt?

Không đưa dữ liệu khách hàng thật vào repo hoặc fixture kiểm thử; chỉ commit mapping cấu hình không nhạy cảm và dữ liệu giả lập.
