# 滴答清单开放 API 契约验证报告

- 状态:**全部计划项已实测完成**;本报告为方案 `docs/ticktick-sync-proposal.md` 阶段 B(接口契约验证)的实测证据。
- 日期:2026-10-14(UTC 时段约 09:48–09:57)。
- 基址:`https://api.dida365.com/open/v1`。
- 认证:使用本机 `~/.config/dida-cli/config.json` 的 `access_token` 以 `Authorization: Bearer` 头发送;该文件未做任何修改;**本报告不含 token、不含账号真实任务标题**;报告中的任务标题仅为本次自建 `[noty-sync-verify]` 测试任务。
- 官方文档对照:`/tmp/noty-ticktick-audit-20261014/developer.dida365.com-openapi.md`(2026-10-14 快照)。
- 请求方式:`curl -sS`,超时等参数与方案附录 A 一致;每个请求的 HTTP 状态、结构、计数均来自当次真实响应,原始 JSON 存于 `/tmp/noty-sync-verify/`(临时,不含凭据)。
- 测试数据边界:写操作仅针对收集箱中标题以 `[noty-sync-verify]` 开头的自建任务(普通任务 A、CHECKLIST 任务 B);验证结束后已全部删除并多通道确认无残留。未触碰任何其他任务或清单。

## 一、只读验证

### 1.1 GET /project(清单列表)

- 请求:`curl -H "Authorization: Bearer $TOKEN" https://api.dida365.com/open/v1/project`
- 结果:HTTP **200**,JSON 数组,**10 个清单**。
- 对象字段并集:`color, id, kind, name, sortOrder, viewMode`(部分清单另有 `groupId`)。`kind` 取值观察到 `TASK`、`NOTE`。
- 关键事实:**列表不包含收集箱本身**。收集箱只能用别名 `inbox` 寻址;其真实 projectId 需从任务数据中获取(本次账号为 `inbox1011272817`,见 1.2)。

### 1.2 GET /project/inbox/data 与 GET /project/{projectId}/data 的结构差异

收集箱:

- 请求:`GET /project/inbox/data` → HTTP **200**。
- 顶层键只有 `columns`、`tasks`,**没有 `project` 字段**(与方案 §2.1 的只读结论一致,本次复现)。
- `columns`:1 个分组对象,字段 `id, projectId(=inbox1011272817), name, sortOrder`。
- `tasks`:19 条,全部 `status=0`。任务的真实 `projectId` 为 `inbox1011272817`(字符串,不是别名 `inbox`)。

普通清单(记为 P1,id `dd304bc59cb99e8098dc0a73`):

- 请求:`GET /project/dd304bc59cb99e8098dc0a73/data` → HTTP **200**。
- 顶层键为 `columns`、**`project`**、`tasks`;`project` 字段是与 `/project` 数组元素同形的清单对象;`columns` 为空数组。
- `tasks`:1 条,status=0,`columnId/columnName` 缺席。

任务字段完整性(收集箱 19 条 + P1 1 条,共 20 条统计):

| 出现频率 | 字段 |
|---|---|
| 20/20(必现) | `id, projectId, sortOrder, title, content, desc, timeZone, isAllDay, priority, progress, isFloating, status, etag, etimestamp, kind, modifiedTime, createdTime` |
| 19/20(可选) | `columnId, columnName`(P1 的任务无) |
| 6/20、4/20、3/20(可选) | `parentId`、`startDate/dueDate`、`childIds` |
| 仅已完成任务出现 | `completedTime`,部分另有 `reminders, repeatFlag, repeatFrom` |

值域:`status∈{0}`(未完成态样本);`kind∈{TEXT}`;`priority∈{0}`;`isAllDay∈{true,false}`。

**解码契约**:17 个字段可视为必现;`project` 顶层字段、`columnId/columnName/parentId/childIds/startDate/dueDate/completedTime` 必须按 optional 解码,不能强制要求。

### 1.3 POST /task/filter

- 请求体字段名确认为 **`projectIds`**(list)。`projectIds:["inbox"]` 与 `projectIds:["inbox1011272817"]` 返回**相同的 ID 集合**(别名与真实 id 等价)。
- `status` 语义:`[0]`=未完成,`[2]`=已完成。
- 与 `/project/{projectId}/data` 的关系:
  - 收集箱:`filter(projectIds=["inbox"], status=[0])` → HTTP 200,**19 条**,ID 集合与 `/project/inbox/data` 的 tasks **完全一致**,且返回顺序也一致。
  - P1:`filter(status=[0])` → 1 条,与 `/project/{pid}/data` 集合一致;`filter(status=[0,2])` → 20 条(1 未完成 + 19 已完成);`filter(status=[2])` → 19 条,是 `[0,2]` 结果的子集,两者已完成集合一致。
  - 收集箱混查 `status=[0,2]` → **200 条(饱和)**,19 未完成 + 181 已完成——与方案 §2.1 一致:混查不是完整历史集合,饱和上限实测恰为 200。
- 日期条件语义(**交叉实验证明不可互换**):
  - 对象:2 个已完成任务,`startDate=2026-10-12T16:00Z`,`completedTime=2026-10-13T15:51Z`。
  - filter 窗口只覆盖 completedTime(10-13 当天)→ 返回 **0**;窗口只覆盖 startDate(10-12 当天)→ 返回 **2**。证明 filter 的日期条件针对**任务 startDate**。
- 返回顺序与 sortOrder 的关系:
  - filter(inbox,status=[0]) 与 inbox/data 返回顺序逐条一致,但序列的 sortOrder 既**非升序也非降序**(首 8 项:`-2199043178497, -16777217, -17825793, -2199042129921, -6291457, -7340033, -8388609, -13631489`)。
  - 已完成结果对 `completedTime` 同样无单调性(非升非降)。
  - **结论:接口返回顺序不能当作任何排序依据;Noty 必须自行显式排序(支持方案 §5.4)。**
- 响应结构:Task 对象数组,字段并集与列表读取一致(完成任务多出 `completedTime` 等)。

### 1.4 POST /task/completed

- 请求参数:`projectIds`(list)、`startDate`、`endDate`,日期条件针对 **completedTime**(文档如此,实测交叉验证:窗口只覆盖上述任务的 startDate(10-12)→ 返回 **0**;`/task/completed` 与 filter 语义不可互换)。
- 返回结构:Task 对象数组(与 filter 同形,已完成任务含 `completedTime`)。
- 时间窗口行为(全部 HTTP 200):

| 窗口 | 返回条数 | 说明 |
|---|---|---|
| 不传日期参数 | 200(饱和) | 等价全量已完成历史,受 200 上限截断,**不是默认完整集合** |
| 最近 24h | 2 | completedTime 为 2026-10-13T15:51:14/12+0000 的两条 |
| 最近 2h | 0 | 空数组 |
| **3 秒极小窗口** | 0 | 空数组、HTTP 200,无报错 |
| 2020-01-01~01-02(历史窗口) | 2 | completedTime 真在 2020-01-01T12:44 的两条,窗口边界包含行为正常 |
| 完成测试任务后的 5 分钟窗口 | 1 | 精确返回刚完成的测试任务,status=2、completedTime=2026-10-14T09:55:35.783+0000 |

- **结论:`/task/completed` 可用作完成操作的权威确认通道**(新完成任务立即出现在对应 completedTime 窗口中,标题保留)。

### 1.5 GET /project/{projectId}/task/{taskId}(单任务回读)

- 用收集箱现有任务测试:真实 projectId 与 `inbox` 别名**均可**,两者返回内容完全一致,HTTP 200,字段集合与列表读取完全一致。
- P1 的任务同样回读成功(HTTP 200)。
- 404 语义:不存在的 taskId → HTTP 404,body:
  `{"errorId":"...","errorCode":"resource_not_found","errorMessage":"task not found: <taskId>","data":null}`
- **projectId 与 taskId 不匹配(合法任务 + 错误清单)同样返回 404** "task not found"——单任务回读必须使用任务实际所属 projectId。
- 删除后的行为见 2.5(重要异常):删除后该接口**仍返回 200**。

## 二、写验证(仅自建 [noty-sync-verify] 测试任务,建于收集箱)

### 2.1 创建 → 完成 → 权威回读 status=2(普通任务 A)

创建(POST /task):

- 请求体:`title="[noty-sync-verify] 基础完成语义 A"`, `projectId="inbox"`, `content/desc/startDate/dueDate=2026-10-20T16:00:00.000+0000/isAllDay=true/timeZone=Asia/Shanghai/priority=3`。
- HTTP **200**(文档列 200/201,实测 200),返回**完整任务对象**;`projectId` 回显真实 id `inbox1011272817`;`status=0`,`kind=TEXT`,自动分配 `sortOrder`;创建响应含 `tags:[]`(后续读取中该字段缺席)。

完成(POST /project/{projectId}/task/{taskId}/complete):

- HTTP **200**,响应体为空数组 `[]`。
- 权威回读(GET 单任务):`status=2`,`completedTime=2026-10-14T09:52:43.922+0000`(毫秒精度),`modifiedTime` 同步更新;**title/content/desc/startDate/dueDate/priority/isAllDay/timeZone/kind 全部保留**。

### 2.2 取消完成(POST /task/{taskId})——方案 §6.4 开放门槛的核心验证

任务 A 反复完成/恢复,共测 4 种字段组合,**全部以单任务回读为权威判定**:

| 组合 | 请求体 | HTTP | 回读 status | 字段保留情况 |
|---|---|---|---|---|
| 1(最小) | `{"id","projectId","status":0}` | 200 | **0** | 完整保留 |
| 2(无 projectId) | `{"id","status":0}` | 200 | **0** | 完整保留 |
| 3(直接完成) | `{"id","projectId","status":2}` | 200 | **2**,completedTime 置新值 | 完整保留 |
| 4(body 无 id) | `{"projectId","status":0}`(id 仅在路径) | 200 | **0** | 完整保留 |

组合 1 的全字段 diff(创建时 vs 取消完成后回读):仅 `completedTime`(残留旧值)、`etag`、`etimestamp`、`modifiedTime` 变化,`tags` 从 `[]` 变为缺席;**标题、日期、内容、优先级、时区、kind、sortOrder 等业务字段一律未被清空**。取消完成后任务**重新出现在 `/project/inbox/data` 未完成列表中**(status=0)。

关键结论:

- **`POST /task/{taskId}` 顶层 `status` 字段真实生效,0/2 均可写**,且组合 1(方案 §6.4 的最小字段集)即可真正恢复任务。文档 Update Task 参数表未列出顶层 status,实测有效——按"真实契约为准"可采信,但需在报告中明示这是文档外行为(见异常 3)。
- **异常:取消完成后 `completedTime` 残留不清空**(组合 1、2、4 回读均带旧 completedTime)。因此 Noty 判断完成状态**只能依赖 `status`,不能以 completedTime 是否存在为证据**。
- CHECKLIST 任务的取消完成同样有效(见 2.4)。
- 覆盖边界:本验证以**服务端权威回读**(单任务 GET + 列表重拉 + completed 窗口)为判定;手机/网页客户端的恢复可见性未在本环境人工核对(方案 §6.4 的该项留待实机验收)。

### 2.3 完成确认通道复核

完成任务 A 后,`POST /task/completed`(5 分钟窗口)立即返回该任务:`status=2`、`completedTime=2026-10-14T09:55:35.783+0000`、标题保留。单任务 GET 回读与 completed 窗口查询双通道均可用作方案 §6.1 的权威确认。

### 2.4 CHECKLIST 类型(kind=CHECKLIST)

创建(POST /task 带 `items`):

- `items` 全部为开放子项时:HTTP **200**,返回 `kind=CHECKLIST`,每个子项获得独立 `id`(含 `sortOrder/timeZone`)。
- **创建时子项带 `status:2` → HTTP 400** `{"errorCode":"invalid_request","errorMessage":"checklist item status is invalid"}`;创建后任务未产生副作用。即创建时子项只能为未完成态。

完成语义(任务 B,3 个子项):

- `POST .../complete` → HTTP 200;回读:父任务 `status=2`、`completedTime` 置值,但 **3 个子项全部仍为 `status=0`,`progress` 仍为 0——父任务完成不会级联完成子项**。
- 取消完成(组合 1 `{id,projectId,status:0}`)→ HTTP 200,回读 `status=0`,**子项与标题完整保留**,kind 仍为 CHECKLIST。
- 尝试通过 Update 的 `items[].status=2` 勾选单个子项(带或不带 `completedTime`)→ 均为 **HTTP 400** `checklist item status is invalid`,任务内容未被破坏。
- **结论:CHECKLIST 父任务的完成/恢复与普通任务同契约;子项无法经开放 API 勾选,方案 §5.4"第一期只展示父任务"的决策被证实是硬边界而非选择。**

### 2.5 DELETE /project/{projectId}/task/{taskId}

- HTTP **200**,响应体空数组 `[]`。
- 任务**立即**从 `/project/inbox/data`(未完成列表)与 `POST /task/filter`(status=[0] 与 [0,2])、`POST /task/completed`(1h 窗口)中消失。
- **重要异常:删除后 1 秒与 40 秒后,单任务 GET 仍返回 HTTP 200 与完整任务数据**(status 保持删除前的值 0/2,projectId 不变,`modifiedTime` 更新为删除时刻)。404 仅出现在从未存在/已彻底不存在的 ID 上。
- 推断:开放 API 的 DELETE 是软删除(进回收站),回收站保留期内单任务回读不返回 404。

### 2.6 清理与残留确认

删除 A、B 后多通道复查:

| 检查通道 | 结果 |
|---|---|
| `GET /project/inbox/data` | 19 条(回到测试前基线),按 ID 与按 `[noty-sync-verify]` 标题前缀双重检查,残留 **0** |
| `POST /task/filter` status=[0] | 19 条,残留 **0** |
| `POST /task/filter` status=[0,2] | 200 条(饱和),残留 **0** |
| `POST /task/completed` 1h 窗口 | 0 条 |

**测试任务已全部清理,无残留。**

## 三、结论表

| 端点 | 验证结论 |
|---|---|
| `GET /project` | ✅ HTTP 200,数组 10 清单,字段 `color/id/kind/name/sortOrder/viewMode`;**不含收集箱本体** |
| `GET /project/inbox/data` | ✅ 200,仅 `columns+tasks`(无 `project`),19 条 status=0;真实 projectId=`inbox1011272817` |
| `GET /project/{projectId}/data` | ✅ 200,`columns+project+tasks`;与 filter(status=[0]) 任务集合一致 |
| `POST /task/filter` | ✅ 200;字段名 `projectIds`;status 0/2 语义确认;日期条件针对 startDate;返回顺序与 sortOrder/completedTime 均无单调性;上限 200 实测饱和 |
| `POST /task/completed` | ✅ 200;`projectIds+startDate+endDate` 针对 completedTime;极小/空窗口返回空数组;无日期参数即饱和 200;可作完成确认通道 |
| `GET /project/{projectId}/task/{taskId}` | ✅ 200,字段与列表一致;inbox 别名可用;错误 projectId 与不存在 taskId 均 404(`resource_not_found`);**删除后仍 200** |
| `POST /task`(创建) | ✅ 200 返回完整任务对象;`items` 可建 CHECKLIST;子项 status≠0 被 400 拒绝 |
| `POST /project/{projectId}/task/{taskId}/complete` | ✅ 200 空数组;回读 status=2、completedTime 置值、其余字段保留;CHECKLIST 父完成不带动子项 |
| `POST /task/{taskId}`(更新/取消完成) | ✅ **顶层 status 生效**:`{id,projectId,status:0}` 可真正恢复任务(权威回读 status=0、字段完整);无 projectId / 无 body id 组合亦生效;status=2 亦可直接完成;completedTime 残留 |
| `DELETE /project/{projectId}/task/{taskId}` | ✅ 200 空数组;列表/filter/completed 立即移除;单任务 GET 不 404(软删除) |

对方案 §6.4/§9.4 的直接回答:**取消完成(普通任务与 CHECKLIST 父任务)已通过端到端验证,可开放**;未覆盖类型仅剩重复任务(repeatFlag)与共享清单,维持只读展示。

## 四、异常发现(与方案假设或官方文档不符处)

1. **取消完成后 `completedTime` 残留**:恢复为 status=0 后旧 completedTime 不清除。实现必须仅以 `status` 判定完成态,`completedTime` 只在 status=2 时解读。
2. **DELETE 后单任务回读不返回 404**(软删除):方案 §5.3"两个独立 404 才移出展示"的规则对服务端删除的任务**永远不会触发**——已删任务 GET 仍 200 且 status/projectId 不变,与"仍在清单内"难以区分。缺失任务的判定需改为:列表缺失 + completed 窗口完整覆盖仍无此 ID + GET 回读无新鲜修改 → 按"已不可访问"移出展示,且**不能宣称任务已删除**。status=-1 从未观测到。
3. **Update Task 文档外行为**:参数表未列顶层 `status`,实测 0/2 均生效;`id`、`projectId` 标注 required,实测省略 body id 或省略 projectId 仍成功(路径 id 优先)。契约按实测采用最小字段集 `{id, projectId, status}` 以求稳,但需知晓文档与实现不一致。
4. **`/task/completed` 不传日期即饱和 200 条**,并非默认近期;近期完成必须始终显式带时间窗口。
5. **filter 与 completed 的日期语义实测不可互换**(filter→任务 startDate,completed→completedTime),与文档一致,但此前曾被怀疑,现已实证。
6. **返回顺序无任何保证**:列表、filter、completed 的返回顺序对 sortOrder、completedTime 均非单调;方案 §5.4 的客户端显式排序(sortOrder 升序 + taskId 次级)是必须项。
7. **收集箱在 `/project` 列表中缺席**:需固定使用别名 `inbox` 读取,写入与单任务回读用任务回显的真实 projectId(本账号 `inbox1011272817`;该值属于账号数据,实现中须动态获取而非硬编码)。
8. **CHECKLIST 子项不可经开放 API 完成**(创建与更新均 400 拒绝非 0 状态);父任务完成也不级联子项。第一期仅展示父任务是 API 硬边界。
9. 小项:创建成功返回 200(而非 201);`tags` 字段在创建响应为 `[]` 而后续读取缺席;inbox 的 columns 非空(默认分组),普通清单 columns 为空数组;错误响应统一为 `{errorId, errorCode, errorMessage, data:null}` 结构。

## 五、给实现的关键契约提醒

- 解码模型:17 个任务字段必现,其余(含顶层 `project`)必须 optional;错误响应是 JSON 对象而非空体,错误分类需按 `errorCode` + HTTP 状态双轨。
- 完成链路:`complete` → GET 回读 status=2 → 移入近期完成(或 completed 窗口确认,双通道均实测可用)。
- 取消完成链路:`POST /task/{taskId}` 最小体 `{id, projectId, status:0}` → GET 回读 status=0;字段安全,仅 completedTime 残留需忽略。
- 排序:丢弃服务端返回顺序,按方案 §5.4 自行排序。
- 删除检测:不依赖 404;见异常 2 的新规则。

## 附:请求命令模板(不含任何凭据)

```bash
TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/.config/dida-cli/config.json'))['access_token'])")
curl -sS -H "Authorization: Bearer $TOKEN" https://api.dida365.com/open/v1/project
curl -sS -H "Authorization: Bearer $TOKEN" https://api.dida365.com/open/v1/project/inbox/data
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"projectIds":["inbox"],"status":[0]}' https://api.dida365.com/open/v1/task/filter
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"projectIds":["inbox"],"startDate":"<RFC3339>","endDate":"<RFC3339>"}' https://api.dida365.com/open/v1/task/completed
curl -sS -H "Authorization: Bearer $TOKEN" https://api.dida365.com/open/v1/project/<projectId>/task/<taskId>
curl -sS -X POST -H "Authorization: Bearer $TOKEN" https://api.dida365.com/open/v1/project/<projectId>/task/<taskId>/complete
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"id":"<taskId>","projectId":"<projectId>","status":0}' https://api.dida365.com/open/v1/task/<taskId>
curl -sS -X DELETE -H "Authorization: Bearer $TOKEN" https://api.dida365.com/open/v1/project/<projectId>/task/<taskId>
```
