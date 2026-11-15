# 安全方案：认证、TLS、密钥轮换（PLAN M3 指引）

> 状态：认证与 token 轮换已实现（`Troupe::Transport::Authenticator` + TCP 握手，见下）；
> TLS 为方案指引，待生产部署迭代落地。

## 认证（已实现）

- 共享 token 模型：`Authenticator` 持 current token + grace 集合；验证为
  **常量时间比较**（`Transport.secure_equals`，无短路时序泄漏）。
- TCP 握手：连接后第一帧必须为 `auth` 信封（携带 token）；校验通过回 `ok:true` 后
  才接受业务信封；失败回 `ok:false`（em=原因）后断连；未认证即发业务帧同样断连。
- 客户端：`TCPClient.new(host, port, token: "...")` 在 reader 启动前同步完成握手
  （无竞争）；ack 读取带 3s 超时，失败/超时统一抛 `Transport::AuthError`。

### 密钥轮换流程（已实现语义）

1. 运维生成新 token → `server_auth.rotate(new)`：新 token 即刻生效，旧 token 进入宽限集；
2. 各客户端逐步切换到新 token（宽限期内旧 token 仍可验证——滚动发布窗口）；
3. 全量切换完成后 `server_auth.revoke_old`：旧 token 立即失效。

反例覆盖：错误 token 握手拒绝；宽限期内旧 token 可用；revoke 后旧 token 拒绝、新 token 不受影响。

## TLS（方案指引，待落地）

- 版本：TLS 1.2 起步，优先 1.3；禁用已知弱套件。
- 证书：生产环境每节点一张节点证书（内部 CA 签发），控制面分发；证书轮换采用
  与 token 相同的"新旧并存宽限 + 撤销"模型（加载新证书于新连接，旧连接自然结束）。
- Crystal 集成点（不引入新依赖到核心）：`require "openssl"` 后
  - 服务端：`OpenSSL::SSL::Server.new(tcp_server, context)` 包裹 listener，accept 得到
    `OpenSSL::SSL::Socket`（`IO` 子类，可直接传入现有 `handle_connection`）；
  - 客户端：`OpenSSL::SSL::Socket::Client.new(tcp_socket, context)` 同理；
  - `TCPServer`/`TCPClient` 增加可选 `tls_context` 参数即可接入，帧协议不变。
  - Windows/MSYS2 构建需 OpenSSL 头文件与链接配置——作为独立迭代验证后再启用。
- 节点间认证路径建议：内部 CA + mTLS（双向证书校验）替代/叠加共享 token；
  共享 token 保留作为非 TLS 环境的最低门槛。

## 密钥管理边界

- token/证书/私钥不入库、不入日志、不入 error message（框架层已保证：认证失败消息
  仅含"token 无效"，不回显提交内容）。
- 轮换周期建议：token 短周期（天级）+ revoke 能力兜底；证书按 CA 策略。
- 泄露响应：rotate + revoke_old 即时生效（无需重启进程）。

## 未验证边界（不宣称）

- TLS 集成未实现、未测试（无 OpenSSL 构建验证）；
- 认证仅保护"连接建立"，不提供 per-call 授权（角色级 ACL 属后续）；
- 重放保护依赖 TLS 记录层或上层幂等键，帧协议本身不防重放。
