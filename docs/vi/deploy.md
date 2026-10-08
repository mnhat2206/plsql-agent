# Deploy và CI/CD

[← README](../../README.vi.md)

## Deploy bằng tay

Sau khi merge vào `main`:

```bash
make deploy BASE=<commit trước khi merge>
```

Tool lần lượt:
1. Lấy các package, function, procedure đã đổi giữa `BASE` và commit hiện tại.
2. Kiểm tra prod vẫn khớp git. Nếu có người sửa ngoài git thì **dừng, không compile gì**, và in ra phần khác.
3. Compile package spec, rồi function và procedure, rồi package body.
4. Đối chiếu lại prod với git. Không khớp thì báo lỗi.

Lần deploy bị lỗi giữa chừng có thể chạy lại an toàn: phần nào đã lên prod rồi thì không bị coi là sửa ngoài git.

Rollback: revert commit rồi deploy lại.

## Tự động bằng GitHub Actions

1. **Settings → Secrets and variables → Actions**
   - **Secrets**: `PROD_USER`, `PROD_PASSWORD`, `PROD_CONNECT`. Nếu dùng TNS thì thay `PROD_CONNECT` bằng `PROD_TNS` và `TNSNAMES_ORA` (nội dung file).
   - **Variables**: `APP_SCHEMA`, `ORACLE_VERSION`, `PLSQL_DEPLOY_ENABLED` = `true`.
2. **Self-hosted runner**: cài trên một máy vào được prod và có Docker, git, make (Settings → Actions → Runners → New self-hosted runner). Gắn label `plsql-deploy`.
3. **Bảo vệ nhánh `main`** và bắt buộc check `pr-check`.

Sau đó:
- **Mỗi Pull Request** (`pr-check`): GitHub dựng Oracle tạm, tạo schema từ `ci/schema/`, rồi compile toàn bộ code. Bước này không dùng thông tin prod.
- **Mỗi lần merge** (`deploy`): runner deploy những gì đã đổi kể từ lần deploy thành công gần nhất, rồi gắn tag `plsql-deployed` vào commit đó. Các lần deploy bị huỷ hoặc thất bại sẽ được gộp vào lần sau. Đừng xoá tag này bằng tay.

Workflow `self-test` chỉ dùng để kiểm thử chính plsql-agent. Trong repo của bạn nó luôn ở trạng thái *skipped*, có thể xoá file `.github/workflows/self-test.yml`.

> ⚠️ Repo chứa code thật nên để **private**. Không gắn self-hosted runner vào repo public: người lạ có thể mở Pull Request để chạy code trên máy đó.

## Khi có người sửa thẳng trên prod

- `make pull PKG=<tên>` tự tạo commit `sync(prod): <tên> drift from prod` chứa bản trên prod, nên thay đổi của họ không bị mất.
- Deploy bị chặn với `prod was changed outside git`. Cách xử lý: `make pull PKG=<tên>`, sửa lại thay đổi của bạn trên nền đó, rồi tạo Pull Request mới.
