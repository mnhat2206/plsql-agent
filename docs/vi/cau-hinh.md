# Cấu hình

[← README](../../README.vi.md)

## File `.env`

| Biến | Bắt buộc | Mặc định | Ý nghĩa |
|---|---|---|---|
| `PROD_CONNECT` | có* | | `host:port/service` của prod |
| `PROD_TNS`, `TNS_ADMIN` | có* | | Dùng TNS alias thay cho `PROD_CONNECT`; `TNS_ADMIN` là thư mục chứa `tnsnames.ora` (đường dẫn tuyệt đối) |
| `PROD_USER`, `PROD_PASSWORD` | có | | Tài khoản prod. Mật khẩu có dấu cách hoặc `#` thì để trong `"..."`, và không được chứa dấu `"` |
| `APP_SCHEMA` | có | | Schema chứa code (package, function, procedure) |
| `ORACLE_VERSION` | | `23` | Version của prod: `11`, `12`, `18`, `19`, `21`, `23` |
| `LOCAL_SYS_PASSWORD` | có | | Mật khẩu DB trên máy (cho cả `SYSTEM` và `APP_SCHEMA`) |
| `LOCAL_PORT` | | `1530` | Cổng của DB trên máy |
| `LOCAL_DB_MEMORY_MB` | | `1024` | Bộ nhớ cho DB trên máy (tối thiểu 768) |
| `DATA_SCOPE` | | `config/data-scope.conf` | File luật dữ liệu |
| `SYNC_MODE` | | `auto` | `auto`: Data Pump, hỏng thì chép thường. `datapump` hoặc `copy`: chỉ dùng một cách |
| `LOCAL_IMAGE`, `SQLCL_VERSION` | | | Đổi image DB trên máy, hoặc ghim version SQLcl |

\* Chọn một trong hai: `PROD_CONNECT`, hoặc `PROD_TNS` + `TNS_ADMIN`.

## Luật dữ liệu (`config/data-scope.conf`)

Cấu trúc của mọi bảng luôn được tạo đủ. File này chỉ quyết định lấy **bao nhiêu dòng**. Mỗi dòng có dạng `<BẢNG> <luật>`:

| Luật | Ý nghĩa |
|---|---|
| `FULL` | Lấy hết các dòng |
| `NONE` | Không lấy dòng nào |
| `LIMIT 5000` | Tối đa 5000 dòng |
| `SAMPLE 10` | Khoảng 10% số dòng |
| `WHERE created_at >= sysdate - 30` | Các dòng thoả điều kiện (lấy tới hết dòng) |

Hai tên đặc biệt:
- `USED <luật>`: áp cho các bảng mà code dùng tới. Tool tự tìm qua `ALL_DEPENDENCIES`, kể cả khi dùng bảng qua view hay function.
- `DEFAULT <luật>`: áp cho mọi bảng còn lại.

Luật ghi riêng cho từng bảng luôn được ưu tiên. Ở mọi luật, **các dòng cha được tham chiếu luôn được kéo thêm**, qua nhiều tầng, nên khoá ngoại hợp lệ và phép join vẫn ra kết quả.

Mặc định:

```
DEFAULT   NONE
USED      LIMIT 5000
```

Muốn lấy hết thì thay bằng `DEFAULT FULL`. Bảng chỉ được dùng qua SQL động (`EXECUTE IMMEDIATE`) thì `USED` không tìm ra, nên phải ghi tay, ví dụ `TEN_BANG LIMIT 5000`. Chạy `make sync-plan` để xem trước kết quả.

DB trên máy chứa được khoảng 11 GB dữ liệu (giới hạn của Oracle Free/XE).

## Version Oracle

`ORACLE_VERSION` quyết định image cho DB trên máy:

| Prod | DB trên máy | Ghi chú |
|---|---|---|
| 19c, 23ai | Oracle Free 23 | Khuyên dùng, chạy tốt trên Mac chip Apple |
| 12.2, 18c, 21c | Oracle XE 21 | Chỉ có bản Intel/AMD; chạy giả lập (chậm) trên Mac chip Apple |
| 11.2 | Oracle XE 18 | Best effort; có thể cần ghim `SQLCL_VERSION` về bản cũ |

## Quyền của user prod

Chỉ cần đăng nhập được và là chủ của `APP_SCHEMA`. Nếu dùng user khác chủ schema thì cần thêm:
- `DATAPUMP_EXP_FULL_DATABASE` để sync;
- `CREATE ANY PROCEDURE` và `ALTER ANY PROCEDURE` để deploy.

Nên dùng user có quyền tối thiểu.
