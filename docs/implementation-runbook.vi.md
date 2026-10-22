# Hướng dẫn triển khai và chạy thử IFRS 9 Retail ECL Engine

> **Mục tiêu:** triển khai engine trên SQL Server 2022, nạp dữ liệu đầu vào theo đúng hợp đồng, chạy ECL và kiểm tra kết quả. Đây là hướng dẫn cho môi trường DEV/UAT; chưa phải phê duyệt production.

## 1. Thứ tự thực hiện

1. **Chuẩn bị database sạch** trên SQL Server 2022; bảo đảm đã có quyền tạo schema/table/procedure. Không chạy thử lần đầu trên database thật.
2. **Triển khai engine** bằng các script `database/001` đến `database/008`, đúng thứ tự ở mục 2.
3. **Kiểm tra cấu hình** trong `ecl_cfg.PoolName`, `ecl_cfg.Scenario`, `ecl_cfg.ScenarioWeightVersion` và `ecl_cfg.ScenarioWeight`.
4. **Nạp Stage/Pool và AccountSnapshot** từ dữ liệu upstream; xác nhận `POOL_NAME`, `STAGE`, `POOL_ID` và `MATURITY_DATE`.
5. **Nạp PD, LGD, EAD, EIR** vào các bảng chuẩn `ecl_stg.*Curve`. Các procedure `usp_LoadPDCurve`, `usp_LoadLGDCurve`, `usp_LoadEADCurve` là bước **kiểm tra dữ liệu đã nạp**, không tự tính PD/LGD/EAD và không tự ETL dữ liệu từ hệ thống nguồn.
6. **Tạo RUN_ID và kiểm soát đầu vào**: đăng ký đủ sáu nhóm ACCOUNT, PD, LGD, EAD, EIR, SCENARIO_WEIGHT; seal manifest; chạy validate và reconcile.
7. **Tính và xuất bản ECL**: chuyển trạng thái CALCULATING → chạy tính ECL → xác nhận đối soát thành công → publish.
8. **Đối chiếu kết quả** theo tài khoản, pool, Stage và nhật ký audit; lưu bằng chứng chạy thử.

## 2. Triển khai database

Chạy từ thư mục gốc repo bằng PowerShell. Thay tên server/database cho đúng môi trường. Ví dụ dưới đây dùng Windows Integrated Authentication và giả định database DEV đã được tạo.

```powershell
$Server = "localhost"
$Database = "IFRS9_ECL_DEV"

$Scripts = @(
  "database/001_create_logical_schema.sql",
  "database/002_run_control.sql",
  "database/003_input_validation.sql",
  "database/004_input_reconciliation.sql",
  "database/005_ecl_calculation.sql",
  "database/006_ead_curve_loader.sql",
  "database/007_pd_curve_loader.sql",
  "database/008_lgd_curve_loader.sql",
)

foreach ($Script in $Scripts) {
  Write-Host "Deploying $Script"
  sqlcmd -S $Server -d $Database -E -b -i $Script
  if ($LASTEXITCODE -ne 0) {
    throw "Deployment stopped at $Script. Fix the error before continuing."
  }
}
```

Nếu một migration lỗi, **dừng ngay**. Các migration không phải tất cả đều idempotent; không chạy lại cả bộ trên database đã triển khai dở. Với database DEV có thể hủy bỏ, cách an toàn là tạo lại database sạch rồi triển khai từ 001.

Kiểm tra phiên bản SQL Server:

```sql
SELECT SERVERPROPERTY('ProductVersion') AS product_version,
       SERVERPROPERTY('ProductMajorVersion') AS product_major_version,
       SERVERPROPERTY('Edition') AS edition;
```

Mục tiêu kiểm thử hiện tại là SQL Server 2022 (major version 16).

## 3. Cấu hình trước khi nạp dữ liệu

### Pool

`ecl_cfg.PoolName` đã được seed trong migration 001. Kiểm tra mã pool upstream có khớp chính xác `POOL_NAME` đã cấu hình không. Ví dụ:

```sql
SELECT POOL_NAME, SEGMENT, IS_ACTIVE
FROM ecl_cfg.PoolName
ORDER BY POOL_NAME;
```

Không tự đổi `POOL_NAME`/`SEGMENT` chỉ để làm hết lỗi mapping; xác nhận với mapping nghiệp vụ và nguồn PD trước.

### Trọng số kịch bản

Mỗi run cần một `VERSION_ID` có hiệu lực tại `PROCESS_DATE` theo `ScenarioWeightVersion`, với đúng ba kịch bản và tổng trọng số bằng 1. Các dòng `ScenarioWeight` chỉ phụ thuộc `VERSION_ID + SCENARIO_CODE`, không lưu `PROCESS_DATE`. Cấu hình mặc định đã thống nhất trong thiết kế là DOWNTURN 0.1568, BASE 0.6864, UPTURN 0.1568. Kiểm tra version trước khi tạo run:

```sql
SELECT v.VERSION_ID, v.VERSION_NAME, v.EFFECTIVE_FROM, v.EFFECTIVE_TO,
       w.SCENARIO_CODE, w.SCENARIO_WEIGHT, w.IS_ACTIVE
FROM ecl_cfg.ScenarioWeightVersion v
JOIN ecl_cfg.ScenarioWeight w ON w.VERSION_ID = v.VERSION_ID
ORDER BY v.VERSION_ID, w.SCENARIO_CODE;
```

Nếu cần bổ sung hoặc thay đổi version, làm theo kiểm soát thay đổi nội bộ; không sửa ngược một version đã dùng cho run đã audit.

## 4. Hợp đồng dữ liệu đầu vào

Mọi bảng đầu vào chuẩn phải được nạp theo cùng `RUN_ID` và `PROCESS_DATE`.

| Đầu vào chuẩn | Grain bắt buộc | Nội dung |
|---|---|---|
| `ecl_stg.AccountSnapshot` | RUN_ID + ACCOUNT_ID | Khách hàng/tài khoản, POOL_NAME, Stage 1/2/3, POOL_ID, maturity date |
| `ecl_stg.PDCurve` | RUN_ID + ACCOUNT_ID + SCENARIO_CODE + FORECAST_PERIOD | PD marginal theo năm cho DOWNTURN, BASE, UPTURN |
| `ecl_stg.LGDCurve` | RUN_ID + ACCOUNT_ID + FORECAST_PERIOD | LGD theo tài khoản và năm |
| `ecl_stg.EADCurve` | RUN_ID + ACCOUNT_ID + FORECAST_PERIOD | EAD theo tài khoản và năm; currency VND |
| `ecl_stg.EIRCurve` | RUN_ID + FORECAST_PERIOD | EIR theo năm, dùng chung cho tài khoản |
| `ecl_cfg.ScenarioWeight` | VERSION_ID + SCENARIO_CODE | Trọng số kịch bản theo phiên bản; không phụ thuộc PROCESS_DATE |

### Stage/Pool và AccountSnapshot

Hai script upstream tham chiếu bảng nguồn mẫu trong database `[DEFAULT]`:

- `database/upstream/001_load_account_stage_pool_source.sql`: tạo/nạp `ecl_stg.AccountStagePoolSource`; mở rộng Stage từ khách hàng xuống hợp đồng.
- `database/upstream/002_load_account_snapshot.sql`: nạp `ecl_stg.AccountSnapshot`, đọc `expiry_date` thành `MATURITY_DATE` và xác nhận `POOL_NAME` có trong danh mục.

**Trước khi chạy:** sửa/đối chiếu các tên database, schema, bảng, cột và mapping trong hai script theo môi trường thật. Không giả định chúng chạy nguyên trạng nếu nguồn không phải `[DEFAULT].dbo.ODR_CONTRACT_LEVEL_IRB` và `[DEFAULT].dbo.CUSTOMER_ODR_LRA_IRB`.

Gọi hai procedure theo thứ tự (sau khi đã tạo RUN_ID và chuyển run sang VALIDATING):

```sql
EXEC ecl_core.usp_LoadAccountStagePoolSource
     @RUN_ID = 12345, @VERSION_ID = 1;

EXEC ecl_core.usp_LoadAccountSnapshot
     @RUN_ID = 12345, @VERSION_ID = 1;
```

Thay RUN_ID và VERSION_ID bằng giá trị thực tế.

### PD, LGD, EAD và EIR

ETL theo từng nguồn/sản phẩm cần chuyển dữ liệu về grain ở bảng trên. Sau khi nạp PD/LGD/EAD, gọi các procedure kiểm tra:

```sql
EXEC ecl_core.usp_LoadPDCurve  @RUN_ID = 12345;
EXEC ecl_core.usp_LoadLGDCurve @RUN_ID = 12345;
EXEC ecl_core.usp_LoadEADCurve @RUN_ID = 12345;
```

Các curve phải phủ **mọi kỳ năm cần thiết đến maturity**; PD phải đủ cả ba scenario. Với kỳ cuối không tròn năm, theo quy ước v1 chỉ thời gian chiết khấu được điều chỉnh; không tự prorate PD hoặc EAD. EIR phải được nạp trực tiếp vào `ecl_stg.EIRCurve`; không có loader EIR riêng trong migration hiện tại.

Nguồn PD hiện có rating/segment/scenario cần được ETL/mapping sang `PDCurve`; loader dùng chung **không** tự ánh xạ `SOURCE_SCENARIO` hoặc tự tính PD. LGD nguồn chỉ có một reporting date cần được ETL thành đường cong năm theo phương pháp LGD được phê duyệt trước khi đưa vào `LGDCurve`; loader dùng chung không tự kéo dài LGD một thời điểm thành curve.

## 5. Quy trình một RUN_ID

Gọi `usp_CreateRun` với `PROCESS_DATE`, `RUN_TYPE='FULL'`, version trọng số kịch bản hiệu lực và `CALCULATION_VERSION`; lấy `@RUN_ID OUTPUT`. Sau đó chuyển trạng thái sang VALIDATING:

```sql
DECLARE @RUN_ID bigint;

EXEC ecl_core.usp_CreateRun
  @PROCESS_DATE = '2026-10-15',
  @RUN_TYPE = 'FULL',
  @SCENARIO_WEIGHT_VERSION_ID = 1, -- thay bằng VERSION_ID hợp lệ thực tế
  @CALCULATION_VERSION = 'ECL-V1',
  @RUN_ID = @RUN_ID OUTPUT;

SELECT @RUN_ID AS RUN_ID;

EXEC ecl_core.usp_TransitionRunStatus
  @RUN_ID = @RUN_ID,
  @NEW_STATUS = 'VALIDATING',
  @EVENT_MESSAGE = N'Load and validate approved input snapshots';
```

Tiếp theo, nạp sáu nhóm dữ liệu của run đó. Ghi nhận mỗi nhóm bằng `usp_RegisterRunInput` với `INPUT_FAMILY` tương ứng `ACCOUNT`, `PD`, `LGD`, `EAD`, `EIR`, `SCENARIO_WEIGHT`; khai báo đúng source/version, số dòng snapshot và `IS_COMPLETE=1` chỉ khi dữ liệu thực sự đầy đủ. Sau đó:

```sql
EXEC ecl_core.usp_SealRunInputs @RUN_ID = 12345;
EXEC ecl_core.usp_ValidateRunInputs @RUN_ID = 12345;
EXEC ecl_core.usp_ReconcileInputSnapshots @RUN_ID = 12345;
```

Không tính nếu có finding severity ERROR/FATAL hoặc reconciliation chưa SUCCEEDED. Sau khi kiểm tra audit và xác nhận đầu vào hợp lệ:

```sql
EXEC ecl_core.usp_TransitionRunStatus
  @RUN_ID = 12345, @NEW_STATUS = 'CALCULATING';

EXEC ecl_core.usp_CalculateECL @RUN_ID = 12345;
EXEC ecl_core.usp_PublishECL @RUN_ID = 12345;
```

Đây là mẫu lệnh điều phối: chỉ chạy calculate khi đã thật sự nạp đủ dữ liệu và đăng ký đúng row count của cả sáu nhóm. Không dùng `VERSION_ID=1` hay `SCENARIO_WEIGHT_VERSION_ID=1` nếu chưa xác nhận version thực tế.

## 6. Kiểm tra kết quả và lỗi

```sql
DECLARE @RUN_ID bigint = 12345; -- thay bằng RUN_ID thực tế

SELECT * FROM ecl_core.RunControl WHERE RUN_ID = @RUN_ID;

SELECT EVENT_ID, EVENT_TYPE, EVENT_STATUS, EVENT_MESSAGE, ROW_COUNT, EVENT_AT
FROM ecl_audit.RunEvent
WHERE RUN_ID = @RUN_ID
ORDER BY EVENT_ID;

SELECT *
FROM ecl_audit.ValidationError
WHERE RUN_ID = @RUN_ID
ORDER BY SEVERITY;

SELECT COUNT_BIG(*) AS DETAIL_ROWS
FROM ecl_result.ECLDetail WHERE RUN_ID = @RUN_ID;

SELECT COUNT_BIG(*) AS ACCOUNT_ROWS,
       SUM(ECL_12_MONTH) AS ECL_12_MONTH,
       SUM(ECL_LIFETIME) AS ECL_LIFETIME,
       SUM(ECL_DEFAULT) AS ECL_DEFAULT,
       SUM(ECL_TOTAL) AS ECL_TOTAL
FROM ecl_result.ECLAccount WHERE RUN_ID = @RUN_ID;

SELECT POOL_NAME, STAGE, ACCOUNT_COUNT,
       ECL_12_MONTH, ECL_LIFETIME, ECL_DEFAULT, ECL_TOTAL
FROM ecl_result.ECLPortfolioSummary
WHERE RUN_ID = @RUN_ID;
```

Run chỉ hoàn tất quy trình xuất bản khi `RUN_STATUS='PUBLISHED'`, audit có validate/reconciliation/publication thành công và số tổng hợp được đối chiếu theo quy tắc báo cáo đã duyệt. Không cộng chồng ECL Stage 3 với ECL lifetime Stage 2.

Nếu lỗi: dừng ở bước lỗi, đọc thông báo SQL và `ecl_audit.ValidationError`/`RunEvent`, sửa dữ liệu nguồn hoặc mapping. Tạo **RUN_ID mới** khi chạy lại; không ghi đè curve hay xóa kết quả của run cũ để ép chạy lại.

## 7. Chạy test tự động bằng dữ liệu giả lập

Chỉ chạy trên database DEV dùng riêng cho test. Chạy theo danh sách trong [SQL Server deployment guide](sql-server-deployment-guide.md) hoặc workflow CI. Bộ test bao gồm loader, lifecycle, input validation/reconciliation, coverage, calculation, publication gate và rollback khi lỗi. Test xanh chỉ xác nhận code trong môi trường test; không chứng minh mapping dữ liệu nghiệp vụ hay production đã sẵn sàng.

## Tài liệu nên đọc

1. [README tiếng Việt](../README.vi.md) — tổng quan và schema.
2. [Deployment guide](sql-server-deployment-guide.md) — triển khai và chạy test.
3. [Canonical input contract](canonical-input-contract.md) và [Input/output contract](input-output-contract.md) — cấu trúc dữ liệu.
4. [Stage/segment/pool mapping](stage-segment-pool-mapping.md) — quy tắc Stage và pool upstream.
5. [Methodology specification](methodology-specification-v1.0.md) — quy ước tính ECL.

**Giới hạn hiện tại:** chưa có một ETL end-to-end hoàn chỉnh cho mọi nguồn PD/LGD/EAD/EIR và mọi sản phẩm. Các loader curve dùng chung chủ yếu kiểm tra dữ liệu đã được ETL vào hợp đồng chuẩn. Trước production cần phê duyệt mapping nguồn, quyền, backup/rollback, monitoring, hiệu năng và runbook vận hành.
