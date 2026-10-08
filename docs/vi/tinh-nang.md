# Các tính năng

[← README](../../README.vi.md)

## Quản lý code
- Package: `src/packages/<tên>.pks` (spec) và `.pkb` (body). Function: `src/functions/<tên>.fnc`. Procedure: `src/procedures/<tên>.prc`.
- Kéo một, nhiều, hoặc toàn bộ chỉ bằng một câu query. Nghìn object mất vài chục giây, và được gom vào một commit.
- Mỗi file phải chứa đúng một object trùng tên file. File có thêm câu lệnh khác bị từ chối, vì khi deploy cả file sẽ chạy trên prod.

## DB trên máy với dữ liệu thật
- Tạo lại toàn bộ cấu trúc schema của prod: bảng, view, sequence, type, function, procedure, package, trigger, index, khoá ngoại.
- Chọn lượng dữ liệu theo từng bảng: lấy hết, không lấy, n dòng, theo phần trăm, hoặc theo `WHERE`.
- `USED`: tự tìm những bảng mà code thật sự dùng, kể cả qua view hay function trung gian, để chỉ lấy dữ liệu cho những bảng đó.
- **Kéo theo dòng cha**: khi chỉ lấy một phần bảng con (ví dụ 5000 `orders`), tool tự lấy đủ các dòng cha được tham chiếu (`customers` của các đơn đó, rồi cha của `customers`...). Khoá ngoại được tạo ở trạng thái VALIDATED.
- `make sync-plan` xem trước số dòng sẽ kéo về.
- Hai cách kéo dữ liệu:
  - Oracle Data Pump (nhanh);
  - chép thường bằng `INSERT ... SELECT`, tự dùng khi Data Pump không chạy được, ví dụ với image Oracle bản *lite*.
- Cột identity sau khi sync tiếp tục đánh số từ sau giá trị lớn nhất đã chép về, nên insert mới không bị trùng khoá.
- DB trên máy được giới hạn khoảng 1,3 GB RAM.

## Deploy an toàn
- Chỉ deploy những gì đã thay đổi.
- Kiểm tra trước khi deploy (phát hiện sửa ngoài git) và đối chiếu sau khi deploy.
- Lần deploy hỏng giữa chừng có thể chạy lại an toàn. Lần deploy bị huỷ hoặc bị bỏ qua được gộp vào lần sau.
- Rollback bằng cách revert commit.

## Phát hiện sửa ngoài luồng
- `make pull` tự commit bản trên prod khi thấy khác git.
- `make drift` so sánh prod với git bất kỳ lúc nào.

## CI/CD
- Mỗi Pull Request: compile toàn bộ code trên một Oracle tạm, không cần thông tin prod.
- Mỗi lần merge: tự deploy qua self-hosted runner.

## Bảo mật
- Mật khẩu chỉ nằm trong `.env` hoặc GitHub Secrets. Mật khẩu được truyền cho SQLcl qua stdin, không bao giờ nằm trên dòng lệnh, và được che thành `***` trong thông báo lỗi.
- DB trên máy chứa dữ liệu thật, nên chỉ mở cổng trên `127.0.0.1`: máy khác trong mạng không vào được.
- Trên prod, tool chỉ chạy `SELECT`, `CREATE OR REPLACE PACKAGE [BODY] / FUNCTION / PROCEDURE` và `ALTER ... COMPILE`. DB link dùng khi sync được tạo ở DB trên máy, và bị xoá ngay sau đó. DB link và job của prod không bao giờ được chép về.
- Lệnh xoá schema chỉ chạy trên đúng container DB của repo, kể cả khi cấu hình bị đặt nhầm.

## Nhiều version Oracle
Hỗ trợ từ 11.2 đến 23ai. Xem [Cấu hình → Version Oracle](cau-hinh.md#version-oracle).
