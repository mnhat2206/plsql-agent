# Xử lý sự cố

[← README](../../README.vi.md)

Bắt đầu bằng `make check`: lệnh này kiểm tra từng bước kết nối và nói rõ cần sửa gì.

**DBeaver báo `ORA-01017: invalid credential`**
Chạy `make info` để xem đúng thông tin. Username phải là giá trị `APP_SCHEMA`, password là `LOCAL_SYS_PASSWORD`. User này chỉ có sau khi `make sync` chạy thành công lần đầu.

**`make sync` báo không tới được prod (`cannot reach prod`)**
- Tool kết nối **từ bên trong Docker**, nên `localhost` trong `PROD_CONNECT` là chính container chứ không phải máy bạn.
- Prod chạy trên máy bạn, qua SSH tunnel, hoặc là một container Docker khác: dùng `host.docker.internal:<cổng>/<service>`.
- Prod trong mạng công ty: bật VPN trước.

**`make sync` in `Data Pump ... did not complete`**
Không sao: với `SYNC_MODE=auto`, tool tự chuyển sang cách chép thường. Muốn bỏ qua lần thử Data Pump thì đặt `SYNC_MODE=copy`.

**Bảng có dữ liệu trên prod nhưng trên máy trống**
Bảng đó không thuộc `USED`, thường vì package dùng nó qua SQL động. Ghi thêm vào `config/data-scope.conf`, ví dụ `TEN_BANG LIMIT 5000`.

**Container bị tắt ngang (`exited`), hoặc SQLcl bị `Killed`**
Docker hết RAM. Tắt bớt các database khác (`make down`), hoặc tăng RAM cho Docker (Docker Desktop → Settings → Resources).

**Deploy báo `prod was changed outside git`**
Có người sửa thẳng trên prod. Xem [Deploy → Khi có người sửa thẳng trên prod](deploy.md#khi-có-người-sửa-thẳng-trên-prod).

**`make compile` báo `only one unit allowed` hoặc `must start with CREATE OR REPLACE`**
Mỗi file chỉ được chứa đúng một `CREATE OR REPLACE PACKAGE [BODY] / FUNCTION / PROCEDURE <tên file>` và kết thúc bằng một dòng `/`. Trước câu đó chỉ được có comment `--`.

**`make up` báo cổng 1530 đã bị dùng**
Đặt `LOCAL_PORT` sang cổng khác trong `.env`, ví dụ `LOCAL_PORT=1531`.
