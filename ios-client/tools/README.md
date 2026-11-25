# 在电脑上导出 iPhone 历史记录

用 Python 3.9 或更高版本和标准库，将自己已经导出、解密的 iPhone 数据库转换成 AirSIM 可导入的 JSON。工具只读取命令中指定的数据库和可选 WAL 文件，全程在电脑上处理。

在本目录运行以下命令。路径可以包含空格。仅迁移短信或通话时，省略另一个数据库参数即可。

```sh
python3 export_iphone_history.py \
  --sms-db "/path/to/sms.db" \
  --calls-db "/path/to/CallHistory.storedata" \
  --source-id my-iphone \
  --output "/path/to/airsim-history.json"
```

- 使用同一份静止的备份快照。如果导出数据库时也取得了配套的写前日志，请显式添加 `--sms-wal "/path/to/sms.db-wal"` 或 `--calls-wal "/path/to/CallHistory.storedata-wal"`。只选主库时，结果只包含已写入主库的记录。
- 每次导出同一部手机都使用相同的 `--source-id`。从多部手机导入时，为各手机取不同的名称。同一来源的稳定记录标识可用于重复导入。请指定一个新的输出文件名。
- 通过隔空投送、USB 或你自己选用的文件传输方式，把生成的 JSON 保存到 iPhone「文件」，再在 AirSIM 选中该文件导入。文件里含明文通讯记录。
- 命令完成后会报告短信和通话数量、正文解析失败而用占位显示的数量，以及因方向或时间字段损坏而跳过的行数。

## 支持的内容

短信表保留发送或接收方向、时间、联系人及群组、来源服务和数据库提供的本机线路。消息归属使用会话、服务及线路，不按手机号码后几位合并。支持普通文本和常见 `attributedBody` 中的纯文本。导入记录只读，包括 iMessage。附件显示为「[附件]」，不读取原始媒体文件。无法解析的消息会保留一条占位记录。邮件地址、未知号码、群聊不会被自动转换成可拨打号码。

通话支持 `ZCALLRECORD` 表，保留现有的标识、方向、开始时间、接通状态、时长及服务类型。缺失状态显示为未知。通话标识字段 `ZUNIQUE_ID` 是有效且非零 UUID 时，输出 `systemID`，供 AirSIM 与之后读取的系统记录核对。备份中的本地参与方标识仅作为来源元数据。

## 自测与格式依据

```sh
python3 -m unittest discover -s . -p 'test_*.py'
```

自测使用临时生成的 SQLite 数据库，覆盖双卡和群聊隔离、iMessage 附件占位、方向、Apple 时间、有效通话 UUID、显式 WAL、重复运行与错误输出清理。

实现采用 Python 自带的 SQLite，适合离线的 macOS、Linux 和 Windows。数据库列映射参考仍在维护的 iLEAPP（MIT），富文本字段的布局与 imessage-exporter（GPL-3.0）的测试记录交叉核对。工具独立实现这些读取规则，不引入上述项目的代码、依赖或网络服务。[iLEAPP 短信字段](https://github.com/abrignoni/iLEAPP/blob/main/scripts/artifacts/sms.py) · [iLEAPP 通话字段](https://github.com/abrignoni/iLEAPP/blob/main/scripts/artifacts/callHistory.py) · [imessage-exporter 的文本记录](https://github.com/ReagentX/imessage-exporter/blob/develop/imessage-database/src/util/streamtyped.rs)
