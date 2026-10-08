# Các lệnh

[← README](../../README.vi.md)

Gõ `make` để xem danh sách ngắn. Mọi lệnh đọc cấu hình từ `.env`.

## Kiểm tra cấu hình

| Lệnh | Tác dụng |
|---|---|
| `make check` | Kiểm tra `.env`, Docker, đăng nhập prod, schema, version, và DB local có tới được prod không. Gặp lỗi thì nói rõ cần sửa gì (sai mật khẩu, sai service, dùng `localhost`...). Chỉ đọc, không đổi gì. |
| `make peek TABLE=customers` | Xem một bảng trên prod, chỉ đọc: số dòng và 10 dòng đầu, kèm số dòng trong DB local nếu có. Thêm `WHERE="id < 100"`, `ROWS=20` nếu cần. |

## DB trên máy

| Lệnh | Tác dụng |
|---|---|
| `make up` | Bật DB trên máy. Lần đầu tải image và tạo DB (vài phút), những lần sau chỉ vài giây. DB được giới hạn khoảng 1 GB RAM (`LOCAL_DB_MEMORY_MB`). |
| `make down` | Tắt DB trên máy. Dữ liệu vẫn được giữ. |
| `make reset-local` | **Xoá hẳn** DB trên máy cùng dữ liệu. |
| `make info` | In thông tin kết nối vào DB trên máy: host, port, service, user, mật khẩu, chuỗi JDBC (DBeaver, SQL Developer), chuỗi EZConnect (PL/SQL Developer, Toad, SQL*Plus) và đoạn `tnsnames.ora`. |
| `make sql` | Mở SQLcl vào DB trên máy bằng user `APP_SCHEMA`. |
| `make sql FILE=thu.sql` | Chạy một file SQL vào DB trên máy. Cũng nhận SQL qua stdin: `scripts/sql.sh < thu.sql`. |

## Kéo dữ liệu từ prod

| Lệnh | Tác dụng |
|---|---|
| `make sync-plan` | Chỉ đọc prod và in ra từng bảng: luật áp dụng, số dòng trên prod, số dòng sẽ kéo về. Không thay đổi gì. |
| `make sync ONLY="customers orders"` | Chỉ tạo các bảng này cùng các bảng cha của chúng, kèm dữ liệu theo `data-scope.conf`. Bỏ qua view, package, trigger, và không ghi đè `ci/schema/`. Hợp để thử lần đầu. |
| `make sync` | Xoá schema trên máy rồi tạo lại từ prod, gồm: mọi đối tượng; dữ liệu theo `config/data-scope.conf`; các dòng cha cần thiết; khoá ngoại. Cuối cùng xuất cấu trúc ra `ci/schema/` (hãy commit thư mục này, PR check sẽ dùng nó). |
| `make ci-schema` | Tạo lại schema trên máy chỉ từ `ci/schema/`: có cấu trúc, không có dữ liệu, không cần prod. PR check dùng lệnh này. |
| `make schema-ddl` | Xuất lại cấu trúc schema trên máy ra `ci/schema/`. `make sync` đã tự gọi lệnh này. |

## Package, function, procedure

| Lệnh | Tác dụng |
|---|---|
| `make pull PKG=pkg_a` | Lấy source mới nhất của một package, function hoặc procedure từ prod vào `src/packages/`, `src/functions/` hoặc `src/procedures/`. Nếu khác git thì tự commit `sync(prod): ...`. Từ chối nếu file đang có thay đổi chưa commit. |
| `make pull PKG="pkg_a pkg_b"` | Như trên, cho nhiều package, gom vào một commit. |
| `make pull-all` | Lấy mọi package, function và procedure của schema bằng một câu query, gom vào một commit. |
| `make compile` | Compile mọi thứ trong `src/` vào DB trên máy: package spec, rồi function và procedure, rồi package body. |
| `make compile PKG=pkg_a` | Compile một package (hoặc nhiều: `PKG="a b"`). Lỗi hiện dạng `src/packages/pkg_a.pkb:35:5: PLS-00103 ...`. Mỗi file phải chứa đúng một `CREATE OR REPLACE PACKAGE [BODY] / FUNCTION / PROCEDURE <tên file>` và kết thúc bằng `/`. |
| `make drift PKG=pkg_a` | So package, function hoặc procedure trên prod với bản trong git (mặc định `HEAD`, đổi bằng `REF=<commit>`). |

## Deploy

| Lệnh | Tác dụng |
|---|---|
| `make deploy BASE=<sha>` | Compile lên prod các package, function, procedure đã đổi giữa `BASE` và commit hiện tại. Xem [Deploy](deploy.md). |

## Kiểm thử

| Lệnh | Tác dụng |
|---|---|
| `make test` | Unit test (trong Docker, khoảng 1 phút). |
| `make lint` | shellcheck cho script, actionlint cho workflow. |
| `make test-integration` | Chạy toàn bộ quy trình trên một database tạm đóng vai prod (khoảng 12 phút, cần khoảng 4 GB RAM trống). |
