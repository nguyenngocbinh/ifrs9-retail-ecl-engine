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

## 4. SQL tham khảo: join Stage xuống cấp hợp đồng

Nguồn Stage là bảng customer-level DEFAULT.dbo.CUSTOMER_ODR_LRA_IRB, còn tài khoản trong engine là hợp đồng từ DEFAULT.dbo.ODR_CONTRACT_LEVEL_IRB. Không được dùng CUSTOMER_ID làm ACCOUNT_ID: một khách hàng có thể có nhiều hợp đồng. Dùng CONTRACT_ID làm ACCOUNT_ID.

**Khóa join nghiệp vụ:** PROCESS_DATE + CUSTOMER_ID + SEGMENT_ODR_LV1. Trong bảng customer-level, segment được lưu ở segment_odr_lv1. Trong đoạn ETL nguồn được cung cấp, segment của hợp đồng được chuẩn hóa từ segment_lv1, segment_lv2 và modul; CTE bên dưới đặt tên cột đã chuẩn hóa là segment_odr_lv1 để áp dụng đúng ba khóa join. Nếu bảng contract thực tế đã có cột chuẩn hóa segment_odr_lv1, có thể dùng trực tiếp cột đó và bỏ CTE chuẩn hóa tương ứng.

Ví dụ dưới đây là SQL tham khảo cho phần Stage/Pool; nó không ghi vào canonical table. Cần xác nhận tên/cấu trúc cột thực tế, MATURITY_DATE, RUN_ID và VERSION_ID trước khi triển khai.

~~~sql
DECLARE @PROCESS_DATE date = '2026-09-30';

WITH ContractNormalized AS (
    SELECT
        c.PROCESS_DATE,
        c.CUSTOMER_ID,
        c.CONTRACT_ID AS ACCOUNT_ID,
        CASE
            WHEN c.segment_lv1 IN (
                'bigcorp 1', 'bigcorp 2', 'medium 1', 'medium 2',
                'micro', 'small', 'upper 1', 'upper 2', 'micro sme'
            ) THEN
                CASE
                    WHEN c.segment_lv1 IN ('bigcorp 1', 'bigcorp 2', 'upper 1', 'upper 2')
                        THEN 'Large'
                    WHEN c.segment_lv1 IN ('medium 1', 'medium 2')
                        THEN 'Medium'
                    WHEN c.segment_lv1 IN ('micro', 'small', 'micro sme')
                        THEN 'Small'
                END
            WHEN c.segment_lv1 = 'khcn' OR (c.segment_lv1 IS NULL AND c.modul = 'cc')
                THEN c.segment_lv2
            WHEN c.segment_lv1 = 'nonbank'
                THEN 'nonbank'
            ELSE 'x'
        END AS segment_odr_lv1
    FROM [DEFAULT].[dbo].[ODR_CONTRACT_LEVEL_IRB] AS c
    WHERE c.PROCESS_DATE = @PROCESS_DATE
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
),
SegmentPool AS (
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
)
SELECT
    c.PROCESS_DATE,
    c.ACCOUNT_ID,
    c.CUSTOMER_ID,
    s.segment_odr_lv1,
    s.bucket,
    sm.STAGE,
    sp.POOL_ID,
    sp.POOL_NAME,
    sp.CUSTOMER_TYPE_MODEL
FROM ContractNormalized AS c
LEFT JOIN [DEFAULT].[dbo].[CUSTOMER_ODR_LRA_IRB] AS s
    ON  s.PROCESS_DATE = c.PROCESS_DATE
    AND s.CUSTOMER_ID = c.CUSTOMER_ID
    AND s.segment_odr_lv1 = c.segment_odr_lv1
LEFT JOIN StageMap AS sm
    ON sm.BUCKET = s.bucket
LEFT JOIN SegmentPool AS sp
    ON sp.SEGMENT = s.segment_odr_lv1
WHERE c.PROCESS_DATE = @PROCESS_DATE;
~~~

Dùng LEFT JOIN để hợp đồng không tìm được Stage hoặc Pool vẫn xuất hiện trong kết quả kiểm tra. Không loại bỏ âm thầm các dòng lỗi trước khi nạp. Stage được đọc từ bucket đã xử lý xong trong bảng customer-level; không tính lại Stage từ DPD/MOB hợp đồng, vì các quy tắc nguồn còn có điều chỉnh riêng cho OD và Corporate.

### SQL procedure triển khai tham khảo

Đã bổ sung script `database/upstream/001_load_account_stage_pool_source.sql`. Sau khi chạy các migration core để tạo schema và bảng RunControl, script này tạo:

- `ecl_stg.AccountStagePoolSource`: kết quả mapping Stage/Pool ở cấp hợp đồng, theo `RUN_ID + ACCOUNT_ID`.
- `ecl_core.usp_LoadAccountStagePoolSource`: procedure đọc PROCESS_DATE từ RunControl, chuẩn hóa segment từ các trường nguồn, JOIN theo ba khóa yêu cầu và lưu kết quả mapping.

Procedure sẽ chặn trường hợp trùng khóa nguồn, bucket không hợp lệ, hợp đồng thuộc segment được hỗ trợ nhưng không có bản ghi Stage, hoặc nạp lặp RUN_ID khi chưa yêu cầu thay thế. Các segment ngoài 10 pool đã cấu hình không được nạp vào bảng này.

Ví dụ chạy trên môi trường dev/test sau khi tạo run:

```sql
EXEC ecl_core.usp_LoadAccountStagePoolSource
    @RUN_ID = 123,       -- thay bằng RUN_ID đã tạo
    @VERSION_ID = 1,     -- thay bằng version nguồn đã phê duyệt
    @REPLACE_EXISTING = 0;
```

Đây là bước staging Stage/Pool. Bước nạp canonical tiếp theo nằm trong `database/upstream/002_load_account_snapshot.sql`, procedure `ecl_core.usp_LoadAccountSnapshot`. Procedure lấy `expiry_date` từ `ODR_CONTRACT_LEVEL_IRB` làm `MATURITY_DATE` và dùng `POOL_NAME` đã được ánh xạ trong `AccountStagePoolSource`; không tạo thêm mapping từ `POOL_ID` sang loại sản phẩm. Giá trị `POOL_NAME` phải tồn tại và đang hoạt động trong danh mục `ecl_cfg.PoolName`, được seed trong migration schema từ danh sách pool chuẩn.

Ví dụ gọi procedure:

```sql
EXEC ecl_core.usp_LoadAccountSnapshot
    @RUN_ID = 123,
    @VERSION_ID = 1,
    @REPLACE_EXISTING = 0;
```

Procedure sẽ chặn load nếu `POOL_NAME` không có trong danh mục, `expiry_date` không hợp lệ, ngày đáo hạn trước ngày xử lý, khóa nguồn không duy nhất, hoặc manifest đã seal mà yêu cầu thay thế dữ liệu. Chạy trên môi trường dev/test và xác minh DDL nguồn trước khi triển khai production.

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
- Mỗi hợp đồng khớp đúng một dòng customer-level theo PROCESS_DATE + CUSTOMER_ID + SEGMENT_ODR_LV1; không để JOIN nhân bản hợp đồng.
- Mỗi dòng tài khoản có đúng một Stage hợp lệ trong (1, 2, 3).
- Mỗi segment retail được chọn map đến đúng một `POOL_ID`.
- Không có customer_id/contract_id NULL; kiểm tra trùng khóa ở grain nguồn và bảo đảm mỗi PROCESS_DATE + CONTRACT_ID tạo tối đa một dòng snapshot. Kiểm tra cả trường hợp bảng customer-level có nhiều dòng cho cùng PROCESS_DATE + CUSTOMER_ID + SEGMENT_ODR_LV1.
- `PROCESS_DATE` đồng nhất với ngày của `ecl_core.RunControl`.
- Snapshot có đủ `ACCOUNT_ID`, `POOL_NAME`, `MATURITY_DATE`, `RUN_ID`, `VERSION_ID`; quy tắc chuyển `CUSTOMER_ID` thành `ACCOUNT_ID` phải được xác nhận theo nguồn dữ liệu, không mặc định hai khóa này tương đương.
- Kết quả Stage/pool mapping được lưu hoặc truy vết theo run để có thể tái lập và giải trình.

## 6. Map vào hợp đồng canonical

Khi chuẩn hóa upstream, các trường tối thiểu liên quan là:

| Canonical `ecl_stg.AccountSnapshot` | Nguồn/mapping |
|---|---|
| `PROCESS_DATE` | `src.process_date`, phải bằng ngày của run |
| `CUSTOMER_ID` | `src.customer_id` |
| `STAGE` | `StageMap` theo `src.bucket` |
| `POOL_ID` | `SegmentPool.POOL_ID` |
| `POOL_NAME` | Lấy trực tiếp từ `SegmentPool.POOL_NAME`; phải khớp danh mục `ecl_cfg.PoolName` |
| `ACCOUNT_ID` | `ODR_CONTRACT_LEVEL_IRB.CONTRACT_ID`; không dùng `CUSTOMER_ID` thay cho khóa hợp đồng |
| `MATURITY_DATE` | Nguồn hợp đồng/khoản vay đã phê duyệt |
| `RUN_ID`, `VERSION_ID`, `IS_ACTIVE` | Do quy trình điều phối và kiểm soát phiên bản upstream cấp |

Engine vẫn chịu trách nhiệm xác thực hợp đồng canonical, tính toán ECL, đối soát và xuất bản. SQL tham khảo trong tài liệu này chỉ chuẩn hóa Stage và pool; nó chưa phải migration triển khai nguồn production.

## 7. Điểm cần xác nhận trước khi triển khai

1. Xác nhận cột segment chuẩn hóa thực tế trong `ODR_CONTRACT_LEVEL_IRB`; ví dụ này tạo `segment_odr_lv1` từ `segment_lv1`, `segment_lv2`, `modul` theo quy tắc đã cung cấp.
2. Có cần lọc Corporate từ một nguồn/segment khác hay không? Query retail mẫu hiện tại không gồm `Large`, `Medium`, `Small`.
3. Xác nhận danh sách `POOL_NAME` trong `SegmentPool` khớp danh mục chuẩn, đặc biệt với `Others`, `CC`, `OD`.
4. `bucket` có phản ánh đầy đủ Stage/SICR theo chính sách IFRS 9 hiện hành không, và quy tắc xử lý bucket NULL/không biết là chặn run hay ngoại lệ được phê duyệt?

Không đưa dữ liệu khách hàng thật vào repo hoặc fixture kiểm thử; chỉ commit mapping cấu hình không nhạy cảm và dữ liệu giả lập.
