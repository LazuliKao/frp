# 重构计划：将 log 包替换为 xlog 包

## 目标
将所有直接使用 `github.com/fatedier/frp/pkg/util/log` 的地方改成使用 `github.com/fatedier/frp/pkg/util/xlog`，并使用 `xlog.FromContextSafe(ctx)` 获取 logger。

## 需要修改的文件列表

包括但可能不限于以下文件：
1. ./client/service.go
2. ./client/api/controller.go
3. ./cmd/frpc/sub/root.go
4. ./cmd/frps/root.go
5. ./pkg/metrics/mem/server.go
6. ./pkg/nathole/controller.go
7. ./pkg/ssh/gateway.go
8. ./pkg/ssh/server.go
9. ./pkg/util/http/handler.go
10. ./pkg/util/http/middleware.go
11. ./pkg/util/vhost/http.go
12. ./pkg/util/vhost/vhost.go
13. ./server/control.go
14. ./server/service.go

此外你可以使用github.com/fatedier/frp/pkg/util/log包的全局搜索功能，然后查找所有使用 log 包的地方进行修改。

## 修改策略

### 1. 有 context.Context 字段的结构体
- 使用 `xlog.FromContextSafe(s.ctx)` 或 `xlog.FromContextSafe(c.ctx)`
- 在方法内部创建 `xl := xlog.FromContextSafe(s.ctx)` 变量
- 将所有 `log.Xxxf()` 调用改为 `xl.Xxxf()`

### 2. 有 context 参数的函数
- 使用 `xlog.FromContextSafe(ctx)`
- 创建 `xl := xlog.FromContextSafe(ctx)` 变量
- 将所有 `log.Xxxf()` 调用改为 `xl.Xxxf()`

### 3. HTTP handler 函数
- 使用 `req.Context()` 获取 context
- 创建 `xl := xlog.FromContextSafe(req.Context())` 变量
- 将所有 `log.Xxxf()` 调用改为 `xl.Xxxf()`

### 4. 没有 context 的地方（两步策略）

#### 第一步：优先寻找 context 传递方案

**A. 给结构体添加 ctx 字段**
- 检查结构体的实例化位置（构造函数）
- 如果调用者有 context 可用，添加 `ctx context.Context` 字段
- 修改构造函数签名，接收 ctx 参数
- 示例：
  ```go
  type Gateway struct {
      ctx         context.Context  // 新增字段
      // ... 其他字段
  }
  
  func NewGateway(ctx context.Context, ...) *Gateway {
      return &Gateway{
          ctx: ctx,  // 保存 context
          // ...
      }
  }
  ```

**B. 给方法/函数添加 ctx 参数**
- 如果是工具函数或方法，添加 `ctx context.Context` 作为第一个参数
- 检查所有调用点，确保能传递 context
- 示例：
  ```go
  // 修改前
  func HandleVisitor(conn net.Conn) {
      log.Tracef("...")
  }
  
  // 修改后
  func HandleVisitor(ctx context.Context, conn net.Conn) {
      xl := xlog.FromContextSafe(ctx)
      xl.Tracef("...")
  }
  ```

**C. 重构架构以支持 context 传递**
- 某些情况需要调整初始化流程
- 例如：将 init() 中的启动改为在 Service.Run() 中启动
- 示例：
  ```go
  // 修改前：在 init() 中自动启动
  func init() {
      sm.run()  // 没有 context
  }
  
  // 修改后：在 Service.Run() 中显式调用
  func (svr *Service) Run(ctx context.Context) error {
      mem.Run(ctx)  // 有 context
  }
  ```

#### 第二步：实在找不到对策时，保留原逻辑

**重要原则：不使用 context.Background()**

如果通过第一步的方案（添加 ctx 字段、添加 ctx 参数、重构架构）仍然无法获取到 context，则保留原有的 `log.Xxxf()` 调用，不做修改。

这种情况可能出现在：
- 第三方库回调函数中，无法传递 context
- CGO 边界代码
- 某些特殊的初始化代码

示例：
```go
// 如果无法获取 context，保留原逻辑
func someCallback(data string) {
    // 无法传递 context，保持使用全局 log
    log.Infof("callback received: %s", data)
}
```

#### 具体文件的处理方案

**pkg/metrics/mem/server.go**：
- ✅ **第一步可行**：重构架构
  - `serverMetrics` 是单例，在 `init()` 中调用 `sm.run()`
  - 移除 `init()` 中的 `sm.run()` 调用
  - 将 `run()` 改为公开方法 `Run(ctx context.Context)`
  - 在 `server/service.go` 的 `Service.Run()` 中调用 `mem.Run(svr.ctx)`
  - 这样可以使用 server 的 context

**pkg/nathole/controller.go**：
- ✅ **第一步可行**：添加 ctx 参数
  - `Controller` 是跨多个客户端会话共享的资源，不应有结构体级别的 ctx
  - 在方法参数中传递 `ctx context.Context`：
    - `HandleVisitor(ctx, conn)` - 调用点在 `server/control.go:448`，调用者 `ctl.ctx` 可用
    - `HandleClient(ctx, msg)` - 调用点在 `server/control.go:453`，调用者 `ctl.ctx` 可用
    - `HandleReport(ctx, msg)` - 调用点在 `server/control.go:458`，调用者 `ctl.ctx` 可用
    - `analysis(ctx)` - 内部方法，接收 ctx 参数
  - `CleanWorker(ctx)` 已有 ctx 参数，只需修改 log 调用

**pkg/ssh/gateway.go**：
- ✅ **第一步可行**：添加 ctx 字段
  - `Gateway` 结构体添加 `ctx context.Context` 字段
  - `NewGateway(ctx, ...)` 在 `server/service.go:276` 被调用，调用者 `svr.ctx` 可用
  - 修改构造函数签名，接收 ctx 参数
  - `handleConn` 方法使用 `g.ctx` 替代 log

**cmd/frpc/sub/root.go & cmd/frps/root.go**：
- ✅ **第一步可行**：创建 root context
  - 在 `log.InitLogger(cfg.Log)` 之后立即创建 root context
  - 使用 `xlog.New().AppendPrefix("frpc")` 创建 logger
  - 使用 `xlog.NewContext(context.Background(), xl)` 创建 context
  - 后续所有代码都可以使用这个 context
- ⚠️ **备选方案**：如果上述方案不可行（例如初始化流程复杂），保留原有的 `log.Xxxf()` 调用

## 详细修改内容

注意：以下修改内容仅列出部分文件的具体修改示例，具体请按照上述策略进行修改。

### 1. client/service.go
**位置**: 第 197-213 行
**修改**: 在 Run() 方法中，Service 有 ctx 字段
**已导入**: xlog 包已在第 40 行导入

```go
// 修改前（第 195-215 行）
if svr.vnetController != nil {
	if err := svr.vnetController.Init(); err != nil {
		log.Errorf("init virtual network controller error: %v", err)
		return err
	}
	go func() {
		log.Infof("virtual network controller start...")
		if err := svr.vnetController.Run(); err != nil {
			log.Warnf("virtual network controller exit with error: %v", err)
		}
	}()
}

if svr.webServer != nil {
	go func() {
		log.Infof("admin server listen on %s", svr.webServer.Address())
		if err := svr.webServer.Run(); err != nil {
			log.Warnf("admin server exit with error: %v", err)
		}
	}()
}

// 修改后
if svr.vnetController != nil {
	if err := svr.vnetController.Init(); err != nil {
		xl := xlog.FromContextSafe(svr.ctx)
		xl.Errorf("init virtual network controller error: %v", err)
		return err
	}
	go func() {
		xl := xlog.FromContextSafe(svr.ctx)
		xl.Infof("virtual network controller start...")
		if err := svr.vnetController.Run(); err != nil {
			xl.Warnf("virtual network controller exit with error: %v", err)
		}
	}()
}

if svr.webServer != nil {
	go func() {
		xl := xlog.FromContextSafe(svr.ctx)
		xl.Infof("admin server listen on %s", svr.webServer.Address())
		if err := svr.webServer.Run(); err != nil {
			xl.Warnf("admin server exit with error: %v", err)
		}
	}()
}
```

### 2. client/api/controller.go
**位置**: 第 90, 95, 100, 104, 145 行
**修改**: handler 方法接收 httppkg.Context 参数，可以通过 c.Req.Context() 获取 context
```go
// 修改前
log.Warnf("...")
log.Infof("...")

// 修改后
xl := xlog.FromContextSafe(c.Req.Context())
xl.Warnf("...")
xl.Infof("...")
```

### 3. cmd/frpc/sub/root.go
**位置**: 第 159 行
**修改**: startService 函数是命令行入口
**策略**: 尝试创建 root context，如果可行则使用 xlog；如果不可行，保留原有的 `log.Xxxf()` 调用

```go
// 选项1: 创建 root context（推荐）
xl := xlog.New().AppendPrefix("frpc")
ctx := xlog.NewContext(context.Background(), xl)
// 后续使用 xlog.FromContextSafe(ctx)

// 选项2: 如果无法创建 root context，保留原逻辑
log.Infof("start frpc service for config file [%s]", cfgFile)
// 保持不变
```

### 4. cmd/frps/root.go
**位置**: 第 115, 117, 124 行
**修改**: runServer 函数是命令行入口
**策略**: 同上，尝试创建 root context，否则保留原逻辑

### 5. pkg/metrics/mem/server.go
**位置**: 第 65, 83 行
**修改**: serverMetrics 的 run() 方法需要添加 context 支持
- **推荐方案**：重构架构，移除 init() 调用，在 server/service.go 的 Service.Run() 中启动
- **备选方案**：如果无法重构，保留原有的 `log.Xxxf()` 调用

### 6. pkg/nathole/controller.go
**位置**: 多处使用 log.Tracef/Debugf/Infof/Warnf
**修改**: Controller 方法添加 ctx 参数
- **推荐方案**：在方法参数中传递 ctx context.Context
- **备选方案**：如果无法添加参数，保留原有的 `log.Xxxf()` 调用

### 7. pkg/ssh/gateway.go
**位置**: 第 78, 127 行
**修改**: Gateway 结构体添加 ctx 字段
- **推荐方案**：添加 ctx context.Context 字段，修改 NewGateway 签名
- **备选方案**：如果无法修改，保留原有的 `log.Xxxf()` 调用

### 8. pkg/ssh/server.go
**位置**: 第 129, 173, 181 行
**修改**: TunnelServer.Run 方法已经创建了 ctx，使用 xlog.FromContextSafe(ctx)

### 9. pkg/util/http/handler.go
**位置**: 第 38 行
**修改**: MakeHTTPHandlerFunc 接收 http.Request 参数
```go
xl := xlog.FromContextSafe(req.Context())
xl.Warnf("...")
```

### 10. pkg/util/http/middleware.go
**位置**: 第 35, 38 行
**修改**: NewRequestLogger 接收 http.Request 参数
```go
xl := xlog.FromContextSafe(req.Context())
xl.Infof("...")
```

### 11. pkg/util/vhost/http.go
**修改**: 需要检查具体使用情况

### 12. pkg/util/vhost/vhost.go
**修改**: 需要检查具体使用情况

### 13. server/control.go
**修改**: 需要检查具体使用情况

### 14. server/service.go
**位置**: 多处使用 log.Infof/Warnf/Tracef/Debugf
**修改**: Service 结构体有 ctx 字段，使用 xlog.FromContextSafe(s.ctx)

## 执行步骤

1. 逐个文件检查当前使用 log 的情况
2. 根据上下文确定如何获取 context
3. 修改 import 语句（如果需要）
4. 修改 log 调用为 xlog 调用
5. 编译检查是否有错误
6. 运行测试确保功能正常

## 注意事项

1. 确保所有修改后的代码都能编译通过
2. 对于没有 context 的地方，优先考虑添加 context 参数或字段
3. **不使用 context.Background()** - 如果实在无法获取 context，保留原有的 `log.Xxxf()` 调用
4. 保持代码风格一致
5. 不要修改 pkg/util/log 和 pkg/util/xlog 包本身

### 2. server/service.go
**位置**: 多处使用 log.Infof/Warnf/Tracef/Debugf
**修改**: Service 结构体有 ctx 字段（第 130 行），使用 xlog.FromContextSafe(s.ctx)
**已导入**: xlog 包已导入

需要修改的行：
- 第 198 行: `log.Infof("tcpmux httpconnect multiplexer listen on %s, passthough: %v", address, cfg.TCPMuxPassthrough)`
- 第 204 行: `log.Infof("plugin [%s] has been registered", p.Name)`
- 第 248 行: `log.Infof("frps tcp listen on %s", address)`
- 第 257 行: `log.Infof("frps kcp listen on udp %s", address)`
- 第 272 行: `log.Infof("frps quic listen on %s", address)`
- 第 281 行: `log.Infof("frps sshTunnelGateway listen on port %d", cfg.SSHTunnelGateway.BindPort)`
- 第 316 行: `log.Infof("http service listen on %s", address)`
- 第 330 行: `log.Infof("https service listen on %s", address)`
- 第 365 行: `log.Infof("dashboard listen on %s", svr.webServer.Address())`
- 第 367 行: `log.Warnf("dashboard server exit with error: %v", err)`
- 第 444 行: `log.Tracef("failed to read message: %v", err)`
- 第 492 行: `log.Warnf("error message type for the new connection [%s]", conn.RemoteAddr().String())`
- 第 505 行: `log.Warnf("listener for incoming connections from client closed")`
- 第 515 行: `log.Tracef("start check TLS connection...")`
- 第 521 行: `log.Warnf("checkAndEnableTLSServerConnWithTimeout error: %v", err)`
- 第 525 行: `log.Tracef("check TLS connection success, isTLS: %v custom: %v internal: %v", isTLS, custom, internal)`
- 第 538 行: `log.Warnf("failed to create mux connection: %v", err)`
- 第 546 行: `log.Debugf("accept new mux stream error: %v", err)`
- 第 564 行: `log.Warnf("quic listener for incoming connections from client closed")`
- 第 572 行: `log.Debugf("accept new quic mux stream error: %v", err)`

**修改策略**: 
在每个方法开始处添加 `xl := xlog.FromContextSafe(svr.ctx)` 或 `xl := xlog.FromContextSafe(s.ctx)`，然后将所有 `log.Xxxf()` 改为 `xl.Xxxf()`。
对于在 goroutine 中的调用，需要在 goroutine 内部创建 xl 变量。

### 3. client/api/controller.go
**位置**: 第 90, 95, 100, 104, 145 行
**修改**: handler 方法接收 httppkg.Context 参数，可以通过 c.Req.Context() 获取 context
**需要添加导入**: `"github.com/fatedier/frp/pkg/util/xlog"`

```go
// 在每个 handler 方法开始处添加
xl := xlog.FromContextSafe(c.Req.Context())

// 然后将所有 log.Xxxf() 改为 xl.Xxxf()
// 第 90 行: log.Warnf("reload frpc proxy config error: %s", err.Error())
// 改为: xl.Warnf("reload frpc proxy config error: %s", err.Error())
```

需要修改的方法：
- `Reload()` 方法（第 90, 95, 100, 104 行）
- `GetConfig()` 方法（第 145 行）

### 4. pkg/ssh/server.go
**位置**: 第 129, 173, 181 行
**修改**: TunnelServer.Run 方法已经创建了 ctx（第 153-154 行），使用 xlog.FromContextSafe(ctx)
**已导入**: xlog 包已导入

```go
// 在 Run() 方法中，已经有：
ctx := xlog.NewContext(context.Background(), xlog.New().AppendPrefix("ssh-tunnel-server"))

// 需要修改的行：
// 第 129 行（在 goroutine 中）: log.Tracef("open conn error: %v", err)
// 改为: xl := xlog.FromContextSafe(ctx); xl.Tracef("open conn error: %v", err)

// 第 173 行: log.Warnf("wait proxy status ready error: %v", err)
// 改为: xl := xlog.FromContextSafe(ctx); xl.Warnf("wait proxy status ready error: %v", err)

// 第 181 行: log.Tracef("ssh tunnel connection from %v closed", sshConn.RemoteAddr())
// 改为: xl := xlog.FromContextSafe(ctx); xl.Tracef("ssh tunnel connection from %v closed", sshConn.RemoteAddr())
```

### 5. pkg/util/vhost/vhost.go
**位置**: 第 208, 218 行
**修改**: Muxer.handle() 方法在第 223 行已经使用 xlog.FromContextSafe(l.ctx) 创建了 xl 变量
**已导入**: xlog 包已导入

```go
// 第 208, 218 行的 log.Debugf() 调用在 xl 变量创建之前
// 需要将 xl 变量的创建移到方法开始处，或者在这两行也创建 xl 变量

// 第 208 行: log.Debugf("get hostname from http/https request host [%s]", host)
// 第 218 行: log.Debugf("get hostname from ssh request [%s]", host)
// 改为: xl.Debugf(...)
```

### 6. pkg/util/vhost/http.go
**位置**: 第 81, 165 行
**修改**: 这些函数可以通过 req.Context() 获取 context
**需要添加导入**: `"github.com/fatedier/frp/pkg/util/xlog"`

```go
// 第 81 行在 Rewrite() 函数中
// 添加: xl := xlog.FromContextSafe(req.Context())
// 将 log.Tracef() 改为 xl.Tracef()

// 第 165 行在 GetRouteConfig() 方法中
// 添加: xl := xlog.FromContextSafe(req.Context())
// 将 log.Debugf() 改为 xl.Debugf()
```

### 7. pkg/util/http/handler.go
**位置**: 第 38 行
**修改**: MakeHTTPHandlerFunc 接收 http.Request 参数
**需要添加导入**: `"github.com/fatedier/frp/pkg/util/xlog"`

```go
// 第 38 行: log.Warnf("do http request [%s] error: %v", req.URL.String(), err)
// 添加: xl := xlog.FromContextSafe(req.Context())
// 改为: xl.Warnf("do http request [%s] error: %v", req.URL.String(), err)
```

### 8. pkg/util/http/middleware.go
**位置**: 第 35, 38 行
**修改**: NewRequestLogger 接收 http.Request 参数
**需要添加导入**: `"github.com/fatedier/frp/pkg/util/xlog"`

```go
// 在 NewRequestLogger 返回的 handler 函数中
// 添加: xl := xlog.FromContextSafe(req.Context())
// 第 35 行: log.Infof("%s - [%s] \"%s %s %s\" %d %d", ...)
// 第 38 行: log.Infof("%s - [%s] \"%s %s %s\" %s", ...)
// 改为: xl.Infof(...)
```

### 9. pkg/ssh/gateway.go
**位置**: 第 78, 127 行
**修改**: Gateway.handleConn 方法需要使用 context
**需要添加导入**: `"github.com/fatedier/frp/pkg/util/xlog"`

```go
// 推荐方案: Gateway 结构体添加 ctx 字段，NewGateway 接收 ctx 参数
type Gateway struct {
    ctx context.Context  // 新增字段
    // ... 其他字段
}

func NewGateway(ctx context.Context, ...) *Gateway {
    return &Gateway{
        ctx: ctx,
        // ...
    }
}

// 在 handleConn 方法中使用
xl := xlog.FromContextSafe(g.ctx)
xl.Errorf("ssh handshake error: %v", err)

// 备选方案: 如果无法修改结构体，保留原有的 log.Errorf() 调用
```

### 10. pkg/nathole/controller.go
**位置**: 多处使用 log.Tracef/Debugf/Infof/Warnf
**修改**: Controller 方法添加 ctx 参数
**需要添加导入**: `"github.com/fatedier/frp/pkg/util/xlog"`

```go
// 推荐方案: 在方法参数中传递 ctx
func (c *Controller) HandleVisitor(ctx context.Context, conn net.Conn) {
    xl := xlog.FromContextSafe(ctx)
    xl.Tracef("...")
}

// 备选方案: 如果无法添加参数，保留原有的 log.Xxxf() 调用
```

### 11. pkg/metrics/mem/server.go
**位置**: 第 65, 83 行
**修改**: serverMetrics 的 run() 方法需要添加 context 支持
**需要添加导入**: `"github.com/fatedier/frp/pkg/util/xlog"`

```go
// 推荐方案: 重构架构
// 1. 移除 init() 中的 sm.run() 调用
// 2. 将 run() 改为公开方法 Run(ctx context.Context)
// 3. 在 server/service.go 的 Service.Run() 中调用 mem.Run(svr.ctx)

// 备选方案: 如果无法重构，保留原有的 log.Debugf()/log.Tracef() 调用
```

### 12. cmd/frpc/sub/root.go
**位置**: 第 159 行
**修改**: startService 函数是命令行入口
**策略**: 尝试创建 root context，如果可行则使用 xlog；如果不可行，保留原有的 `log.Xxxf()` 调用

```go
// 推荐方案: 在 log.InitLogger 后创建 root context
xl := xlog.New().AppendPrefix("frpc")
ctx := xlog.NewContext(context.Background(), xl)
// 后续使用 xlog.FromContextSafe(ctx)

// 备选方案: 如果无法创建 root context，保留原逻辑
log.Infof("start frpc service for config file [%s]", cfgFile)
// 保持不变
```

### 13. cmd/frps/root.go
**位置**: 第 115, 117, 124 行
**修改**: runServer 函数是命令行入口
**策略**: 同上，尝试创建 root context，否则保留原逻辑

```go
// 推荐方案: 创建 root context
xl := xlog.New().AppendPrefix("frps")
ctx := xlog.NewContext(context.Background(), xl)

// 备选方案: 保留原逻辑
log.Infof("frps uses config file: %s", cfgFile)
log.Infof("frps uses command line arguments for config")
log.Infof("frps started successfully")
// 保持不变
```

## 修改顺序建议

1. 先修改已经有 ctx 字段的结构体（client/service.go, server/service.go）
2. 修改可以从 HTTP request 获取 context 的（client/api/controller.go, pkg/util/http/*.go, pkg/util/vhost/*.go）
3. 修改已经创建了 ctx 的方法（pkg/ssh/server.go, pkg/util/vhost/vhost.go）
4. 修改需要添加 ctx 字段/参数的（pkg/ssh/gateway.go, pkg/nathole/controller.go, pkg/metrics/mem/server.go）
   - 优先尝试添加 ctx 字段或参数
   - 如果无法修改，保留原有的 `log.Xxxf()` 调用
5. 最后处理命令行入口函数（cmd/frpc/sub/root.go, cmd/frps/root.go）
   - 尝试创建 root context
   - 如果不可行，保留原有的 `log.Xxxf()` 调用

## 验证步骤

1. 修改完成后运行: `go build ./...`
2. 检查是否有编译错误
3. 运行测试: `go test ./...`
4. 确保所有测试通过

