# ChatGPT Account Desk

macOS 14+ 的本地多账号 ChatGPT 会话管理器。每个账号使用独立的 WebKit 持久数据仓库，可在右侧账号列表切换。名称、邮箱、订阅级别和到期日期保存在 `~/Library/Application Support/ChatGPTAccountDesk/accounts.json`；密码由 ChatGPT 登录页面处理，应用不读取或保存密码。

## 构建与运行

```sh
zsh scripts/build-app.sh
open "build/ChatGPT Account Desk.app"
```

需要 macOS 14+ 和 Apple Command Line Tools。生成的 `.app` 位于 `build/`，采用本机临时签名，未经过 Apple 公证。

仓库中的 `dist/ChatGPT-Account-Desk-v0.2.4-macos.zip` 是对应 `v0.2.4` 标签的 macOS 应用包，解压后即可得到 `.app`。

图标母图为 `Resources/AppIcon-source.png`；构建脚本会生成多尺寸的 `Resources/AppIcon.icns` 并放入应用包。

## 使用

点击右侧 `+` 添加账号并命名，然后在左侧 ChatGPT 页面登录。选中账号后，可在右侧编辑名称、邮箱、订阅级别和到期日期，点击“保存”。账号菜单支持重命名和删除；删除会清除该账号在本机的 WebKit 网站数据，不会删除线上 ChatGPT 账号。

登录 ChatGPT 后，应用会从左下角的账号入口自动识别当前订阅级别；也可以点击“从当前页面读取”立即更新。在 ChatGPT 的账号设置中打开订阅详情后，应用还会尝试识别明确标示的到期日期。未识别到时保留已有数据并显示“未获取”。自动续费的“下次扣费日”不等于到期日，不会写入到期字段。ChatGPT 没有向此应用提供稳定的公开订阅信息接口，页面内容变化可能导致读取失效；此时可以手动填写。

选中账号并打开其 ChatGPT 页面后，点击“查看当前会话”，可读取并查看 `https://chatgpt.com/api/auth/session` 的响应；弹出面板支持复制内容。响应可能包含访问令牌，仅在当前面板中临时展示，不写入账号列表文件。复制后内容会留在系统剪贴板中，请谨慎分享。

网页输入框与右侧账号资料字段支持 macOS 标准的撤销、重做、剪切、复制、粘贴和全选快捷键，也可从菜单栏“编辑”中使用这些命令。

这是独立的第三方容器，不是 OpenAI 官方客户端。部分第三方身份提供商可能拒绝嵌入式浏览器登录；这种限制由提供商决定。
