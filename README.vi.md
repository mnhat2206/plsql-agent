<div align="center">
  <h1>plsql-agent</h1>
  <p>Để AI agent sửa Oracle PL/SQL an toàn: code trong git, chạy thử trên dữ liệu thật, deploy có kiểm soát.</p>

  <a href="https://github.com/mnhat2206/plsql-agent/actions/workflows/self-test.yml"><img src="https://github.com/mnhat2206/plsql-agent/actions/workflows/self-test.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
  <img src="https://img.shields.io/badge/Oracle-11g%20%E2%80%93%2023ai-F80000" alt="Oracle 11g – 23ai">
  <img src="https://img.shields.io/badge/works%20with-Claude%20Code-D97757" alt="Claude Code">

  <p>
    <a href="docs/vi/cac-lenh.md">Tài liệu</a> •
    <a href="README.md">English</a> •
    <a href="https://github.com/mnhat2206/plsql-agent/issues">Báo lỗi</a>
  </p>
</div>

## plsql-agent là gì?

Một môi trường làm việc giúp AI agent như [Claude Code](https://claude.com/claude-code) sửa package, function và procedure PL/SQL **mà không bao giờ ghi vào prod**.

Bạn mô tả việc cần làm. Agent lấy code mới nhất từ prod, sửa, compile và chạy thử trên một Oracle ở máy bạn có dữ liệu copy từ prod, rồi mở Pull Request. Prod chỉ thay đổi khi bạn merge, và deploy tự dừng nếu có ai sửa prod ngoài git.

> **Bạn:** Sửa `get_customer_name` trong `pkg_customer`: không tìm thấy thì trả về 'N/A'. Chạy thử cho tôi xem.
>
> **Claude:** Đã pull `pkg_customer`, sửa nhánh `NO_DATA_FOUND`, compile OK. Chạy thử trên DB local: `get_customer_name(42)` → `Customer 42`, `get_customer_name(-1)` → `N/A`. Đã mở PR #12.

Không cần AI cũng dùng được: mọi việc agent làm đều là lệnh `make` bạn tự chạy được.

## Tính năng

- Package, function, procedure là các file trong git
- DB local có đủ cấu trúc và dữ liệu chọn lọc của prod
- Tự kéo theo dòng cha, khoá ngoại luôn hợp lệ
- Agent chỉ đọc prod qua các lệnh có sẵn, không bao giờ ghi vào prod
- Phát hiện khi có người sửa thẳng trên prod
- Deploy chỉ những gì đã đổi, kiểm tra trước và sau
- CI/CD với GitHub Actions
- Oracle 11g đến 23ai

## Cài đặt

Cần [Docker Desktop](https://www.docker.com/products/docker-desktop/), [git](https://git-scm.com/downloads), make, và [Claude Code](https://claude.com/claude-code) nếu muốn làm việc cùng AI.

Bấm **Use this template** ở đầu trang để tạo repo **private** của bạn (code PL/SQL thật sẽ nằm ở đó), rồi clone về:

```bash
git clone https://github.com/<bạn>/<repo-của-bạn>.git
cd <repo-của-bạn>
cp .env.example .env
```

Điền thông tin prod vào `.env`:

```bash
PROD_CONNECT=10.0.0.5:1521/ORCLPDB1   # host:port/service
PROD_USER=ecom_dev
PROD_PASSWORD="mat-khau"
APP_SCHEMA=ECOM_DEV                   # schema chứa code
ORACLE_VERSION=19
```

Kiểm tra `.env` và kết nối. Lỗi gì lệnh này cũng nói rõ cần sửa chỗ nào:

```bash
make check
```

## Bắt đầu

```bash
make up          # bật DB local
make sync        # copy cấu trúc và dữ liệu từ prod
make pull-all    # đưa package, function, procedure vào git
```

Mặc định chỉ copy dữ liệu cho các bảng mà code dùng tới. Xem trước bằng `make sync-plan`, đổi trong [`config/data-scope.conf`](docs/vi/cau-hinh.md#luật-dữ-liệu-configdata-scopeconf).

Rồi mở agent trong thư mục repo:

```bash
claude
```

File [`CLAUDE.md`](CLAUDE.md) đã dặn sẵn agent quy trình và các giới hạn: không tự chạy SQL trên prod, chỉ chạy thử trên DB local, luôn compile trước khi xong, mở Pull Request thay vì sửa `main`.

## Tự làm không cần AI

```bash
make pull PKG=pkg_customer      # lấy code mới nhất từ prod
# sửa src/packages/pkg_customer.pkb
make compile PKG=pkg_customer   # lỗi hiện theo file:dòng:cột
make sql                        # chạy thử trên DB local
```

`make info` in thông tin kết nối cho DBeaver hay PL/SQL Developer. `make peek TABLE=customers` xem nhanh một bảng trên prod (chỉ đọc).

## Deploy

```bash
make deploy BASE=<commit trước khi merge>
```

Hoặc để GitHub Actions tự deploy sau mỗi lần merge. Xem [hướng dẫn cài CI/CD](docs/vi/deploy.md).

## Tài liệu

- [Các lệnh](docs/vi/cac-lenh.md)
- [Cấu hình](docs/vi/cau-hinh.md)
- [Deploy và CI/CD](docs/vi/deploy.md)
- [Tính năng chi tiết](docs/vi/tinh-nang.md)
- [Xử lý sự cố](docs/vi/xu-ly-su-co.md)

## Giấy phép

[MIT](LICENSE)
