---
date: "2026-11-18"
updated: "2026-11-18"
---

# PostgreSQL 部署

星记可单机离线使用。需要让手机和电脑同步时，管理员只需为它们部署一次数据库。以下操作适用于 PostgreSQL 结构 v2，项目在 PostgreSQL 16 上做过验证。

| 数据库现状 | 管理员操作 |
| --- | --- |
| 新库，尚无星记结构 | 执行 [001_init.sql](001_init.sql)，再创建日常登录账号 |
| 正在使用星记 v1 | 在原库执行 [002_permanent_delete.sql](002_permanent_delete.sql) |
| 已是 v2 | 直接配置设备和授权 |

在已有星记数据库中执行 `SELECT xingji.api_version();` 可查询结构版本，结果为 `2` 表示已升级。下文的命令都从包含这两个 SQL 文件的目录运行。请替换示例连接参数，密码在提示时输入。

## 现有数据库升级到永久删除功能（结构 v2）

升级脚本在一个事务中执行，可重复运行。它添加永久删除所需的表、索引和函数，保留已有备忘录。使用此功能的各端应更新到支持结构 v2 的版本（0.3.0 起）。

由 schema 所有者或 PostgreSQL 管理员在当前使用的数据库执行。以下示例连接本机默认端口的 `xingji` 库。

```powershell
psql -h 127.0.0.1 -p 5432 -U postgres -d xingji -W -v ON_ERROR_STOP=1 -f ./002_permanent_delete.sql
```

也可用数据库管理软件连接目标库，以管理员身份执行整个 SQL 文件。完成后查询结构版本。客户端的日常账号只用于同步，结构升级使用管理员账号。

未升级时，普通同步照常工作；本机提交的永久删除会持久排队，顶部提示执行升级脚本，不会误报已经同步删除。升级后点击“立即同步”即可继续处理。

永久删除后 `records` 中的内容移除，`changes` 对应行的旧密文清空，`purges` 仅保留一份不含标题正文的认证标记。同步游标仍连续，防止离线设备/旧备份把同一记录复活。既有备份、数据库 WAL/磁盘快照不属于这一功能的擦除范围；物理文件大小由数据库常规空间回收机制决定。

## 新数据库初始化

建议在局域网或 VPN 内运行数据库。客户端默认校验 TLS 证书及主机名，可选择 CA PEM 文件。测试用的无 TLS 模式须在界面显式勾选。

用数据库管理员执行（不要在命令行写数据库密码）：

```powershell
psql -h 127.0.0.1 -p 5432 -U postgres -d xingji -W -v ON_ERROR_STOP=1 -f ./001_init.sql
```

## 设备账号与授权

在 psql 创建日常设备账号，通过 `\password` 交互设置口令。

```sql
CREATE ROLE xingji_pc LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
GRANT xingji_client TO xingji_pc;
\password xingji_pc
```

客户端首次同步会创建对应资料库，授予当前数据库登录角色访问权。后续设备可用同一登录角色；若使用独立角色，管理员授权同一个资料库：

```sql
CREATE ROLE xingji_phone LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
GRANT xingji_client TO xingji_phone;
\password xingji_phone
INSERT INTO xingji.vault_access(vault_id,db_role)
VALUES ('从星记设置页复制的资料库UUID','xingji_phone');
```

日常账号没有底层表读写权限，只能执行固定函数。授权依据是 PostgreSQL 的 `session_user`，设备 ID 不是访问凭证。初始化脚本所在 schema 必须由管理员持有，不能授予客户端 CREATE 或所有者权限。

禁用设备：

```sql
ALTER ROLE xingji_phone NOLOGIN;
UPDATE xingji.devices SET revoked=true WHERE db_role='xingji_phone';
DELETE FROM xingji.vault_access WHERE db_role='xingji_phone';
```

若账号共用，单独禁用不透明 device_id 只能阻止该 ID，不能阻止同一账号再注册设备。需要独立账号才能真正分别撤销访问。

`changes` 的游标元数据与永久删除标记保留，历史游标一直有效；永久删除会清空对应旧密文。不要手工删除变更行或重置游标。数据库备份应包含整个 `xingji` schema；业务字段在客户端加密，表仍能显示记录数量、密文长度、写入时间及访问元数据。

主密码变更只重新包装资料库密钥，不能撤销已复制的旧备份或旧密钥。密钥轮换不在此版本中实现。
