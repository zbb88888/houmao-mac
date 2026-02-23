# TODO-REMOVE

硬编码的固定变量，未来需要改为用户可配置。

代码中以 `// TODO-REMOVE` 注释标记，方便全局搜索。

| 变量 | 当前值 | 位置 | 改造方向 |
|------|--------|------|----------|
| model | `"minicpm-o-4.5"` | `AiTxtClient.swift:44` | Worker 模型增加 `model` 字段，Settings 页面可编辑，AiTxtClient.ask() 接收参数 |
| default base URL | `"http://localhost:8080"` | `AiTxtClient.swift:7` | AppSettings 增加 `defaultBaseURL`，Settings 页面可编辑 |
