# Stage 02 Handoff Summary — E-commerce Customer Repurchase Prediction & Analytics

> **项目阶段：** 02 · SQL & EDA → 03 · Machine Learning  
> **整理日期：** 2026-11-11  
> **数据来源：** UCI Online Retail II（两个年度工作表）  
> **状态说明：** 本文仅记录已执行、已检查或在此前对话中明确确认的工作。`[已验证]` 为已观察到的结果；`[当前约定]` 为现阶段的分析定义；`[待核实]` 为尚未证实或尚未正式实现的内容。

## 0. Executive Summary

Stage 02 已完成从原始交易明细到**多预测时点客户级候选建模数据集**的首轮端到端处理：数据导入、跨工作表去重、SQL 数据质量检查、取消/退货候选匹配、订单级聚合、RFM 特征与未来复购标签构造，以及 Python 端质量验证。

**最重要的交接结论：** 当前模型预测的是**未来三个月是否出现新的候选正向付费订单事件**，**不是**“最终未退货的完成购买”或净营收。取消/退货匹配已作为独立分析完成，但**尚未用于过滤当前 Snapshot 的 RFM 或标签**，以避免不可靠匹配和未来信息泄漏。

| 数据层 | 已确认的规模 | 状态 / 说明 |
|---|---:|---|
| 两张原始 Excel 工作表合计 | 1,067,371 行 | `[已验证]` 原始行级数据，含跨工作表重叠 |
| `transactions_deduplicated` | 1,044,848 行 | `[已验证]` 排除重复收录的 22,523 行 |
| 正价格候选付费明细（排除 `TEST001` 前） | 791,045 行 | `[已验证]` 满足四项基础条件 |
| `paid_orders_candidate` | 36,969 笔 | `[已验证]` 排除 `TEST001` 前的候选订单 |
| `order_summary` | 36,960 笔 | `[已验证]` 排除明确测试商品后的实体订单表 |
| `customer_snapshots_candidate` | **17,957 行 × 6 列** | `[已验证]` 6 个 Cutoff，客户 × 预测时点粒度 |
| Train / Validation / Test | **12,426 / 2,718 / 2,813** | `[已验证]` 按 Cutoff 时间划分 |

---

## 1. 原始数据、导入与数据粒度

### 1.1 数据来源与规模 `[已验证]`

使用 UCI **Online Retail II** 两个年度工作表：

| 原工作表 | 明细行数 | 已观察到的 InvoiceDate 范围 |
|---|---:|---|
| `Year 2009-2010` | 525,461 | 2009-12-01 07:45:00 至 2010-12-09 20:01:00 |
| `Year 2010-2011` | 541,910 | 2010-12-01 08:26:00 至 2011-12-09 12:50:00 |
| **合计（去重前）** | **1,067,371** | 两张表在 2010 年 12 月存在重叠 |

Excel 的 8 个原始字段：`Invoice`、`StockCode`、`Description`、`Quantity`、`InvoiceDate`、`Price`、`Customer ID`、`Country`。合并时新增 `SourceYear`，用于识别来源工作表；MySQL 使用相应的 snake_case 列名及 `row_id` 自增主键。

**原始数据粒度：** 一行是**订单中的一条商品/收费明细（order line item）**，不是一张订单，也不是一个客户。

### 1.2 已完成的存储与导入 `[已验证]`

- Windows + VS Code / Jupyter；Python 3.13.0、Pandas 2.2.3；使用 `openpyxl` 读取 Excel、`pyarrow` 保存 Parquet。
- 合并的中间文件已成功保存并回读：`data/interim/online_retail_ii_combined.parquet`；原始与合并数据规模已检查。
- `Invoice`、`StockCode`、`Description` 在 Pandas 中被统一为字符串类型，以处理混合 Excel 类型；`InvoiceDate` 为时间类型。
- 通过 SQLAlchemy + PyMySQL 分批向 MySQL 导入 **1,067,371** 行，并核对数据库行数及 NULL 数量。导入是一次性完成的，**不要重新运行 append 导入脚本**，以免重复插入。
- 数据库：MySQL Server 8.3；Schema：`ecommerce_repurchase`；基础表：`transactions_raw`；`row_id` 是自增主键。
- MySQL 数据目录经此前检查位于 `D:\ProgramData\MySQL\MySQL Server 8.3\Data`（D 盘机械硬盘）。**当前是否迁移到 SSD：未实施 / 待核实**。
- 数据库中已建立索引 `idx_invoice_customer (invoice, customer_id)` 与 `idx_purchase_matching (customer_id, stock_code, price, quantity, invoice_date)`。

### 1.3 关键缺失情况 `[已验证]`

| 来源 | Customer ID 缺失 | Description 缺失 |
|---|---:|---:|
| 2009–2010 | 107,927（约 20.54%） | 2,928（约 0.56%） |
| 2010–2011 | 135,080（约 24.93%） | 1,454（约 0.27%） |
| **两张原表合计** | **243,007** | **4,382** |

上述合计是**导入前 / 去跨工作表重叠前**的统计口径。缺少 Customer ID 的明细无法直接构建客户级复购样本，因此被排除在候选正向付费明细之外；这也意味着存在**客户可识别性带来的样本选择偏差**。

---

## 2. SQL EDA 与数据质量发现

### 2.1 跨年度工作表重叠 `[已验证并处理]`

- 两张工作表之间有 **1,088 个 Invoice** 跨来源重复出现。
- 重叠日期区间是 **2010-12-01（含）至 2010-12-10（不含）**。
- 两个工作表在该区间各有 **22,523 条明细、1,088 个 Invoice**。
- 对重叠区间按所有业务字段分组，并比较两个来源中每个组合的**出现次数**，发现不匹配组合数为 **0**；因此在已比较字段与重复次数层面，两套记录相同。
- 去重策略：**仅排除第二张工作表在该区间的行**，保留第一张的对应记录。

已保存的 View 逻辑：

```sql
CREATE VIEW transactions_deduplicated AS
SELECT *
FROM transactions_raw
WHERE NOT (
    source_year = '2010-2011'
    AND invoice_date >= '2010-12-01'
    AND invoice_date < '2010-12-10'
);
```

结果：**1,067,371 − 22,523 = 1,044,848 行**。

### 2.2 同一工作表内完全相同的明细 `[已发现，未直接删除]`

- 2009–2010：`duplicated().sum()` = **6,865**。
- 2010–2011：`duplicated().sum()` = **5,268**。
- 完全相同的明细可能来自合法重复购买同款商品，也可能是数据重复；**没有足够证据直接删除**。
- 因此，当前去重 **只解决跨工作表重叠**，不声称已完成所有潜在重复记录处理。

### 2.3 Quantity、Price 和取消标记 `[已验证]`

对 `transactions_deduplicated`：

| 异常 / 情况 | 行数 | 备注 |
|---|---:|---|
| `price < 0` | 5 | `stock_code='B'`、`Adjust bad debt`，Customer ID 缺失；不属正常购买 |
| `price = 0` | 6,024 | 不能一概视为零元销售或赠品 |
| `quantity = 0` | 0 | 已验证 |

零价格明细细分：

| Quantity | Customer ID | 行数 |
|---|---|---:|
| Negative | Missing | 3,393 |
| Positive | Missing | 2,561 |
| Positive | Present | 70 |

对 70 条“正数量 + 有客户 + 零价格”明细进行同客户、同 Invoice 的 `EXISTS` 检查：**61 条所在订单有候选付费商品明细，9 条没有**。因此不能仅凭单行 `price=0` 判断整单是否有效。当前正向付费明细规则排除零价格行，但一张订单如果另有正价付费行，仍保留订单事件。

此外，Invoice 以 `C` 开头的明细通常是取消/退货；两张原表均发现**非 C 开头但负数量、零价格且客户缺失**的记录（2009–2010：2,121；2010–2011：1,336），可能属于库存调整，不作为正常正向购买。详细业务原因未被证明。

### 2.4 明确测试商品 `[已验证并纳入候选正向明细过滤]`

- `stock_code='TEST001'`，`description='This is a test product.'`。
- 共 **15 条明细、15 个 Invoice、5 位客户**；`SUM(quantity * price) = 202.50`（**带符号合计**，不可直接等同为需要扣除的销售额）。
- 有测试商品的价格为正，因此仅用 `price > 0` 无法排除测试数据。
- 当前只对**明确识别的 `TEST001`** 做排除；没有使用宽泛的 `LIKE '%TEST%'` 规则。

### 2.5 订单—客户及时间一致性 `[已验证]`

在**排除 TEST001 之前的 36,969 笔候选正向付费订单**中：

- `HAVING COUNT(DISTINCT customer_id) > 1` 检查：**0 个 Invoice** 对应多个客户。
- **64 笔** Invoice 存在多个不同的 `InvoiceDate`（约 **0.173%**）。
- 每笔最多有 **2 个不同时间戳**；最大时间差 **2 分钟**；超过 1 小时 **0 笔**。
- `[当前约定]` 订单日期采用 `MIN(invoice_date) AS order_date`，作为首次出现时间的代理值；不宣称其必然等于真实下单时间。

### 2.6 候选正向付费口径与销售额 `[已验证]`

初始候选明细条件（尚未排除 `TEST001`）：

```sql
WHERE customer_id IS NOT NULL
  AND invoice NOT LIKE 'C%'
  AND quantity > 0
  AND price > 0
```

基于 `transactions_deduplicated` 的结果：

| 指标 | 结果 |
|---|---:|
| `paid_lines` | 791,045 |
| `paying_customers` | 5,878 |
| `paid_orders`（Invoice × Customer） | 36,969 |
| `SUM(quantity * price)` | 17,431,551.178 |

**金额是 Gross Positive Transaction Amount**，尚未扣除取消、退货或其他财务调整，也可能包含非普通商品的收费明细。原币种／币种单位是否已在项目文档中明确：`[待核实]`；此处不自行标记货币符号。

建立 `positive_purchase_lines` 后在上述四条件之外加入：

```sql
AND stock_code <> 'TEST001'
```

基于该 View 的订单实体表 `order_summary` 为 **36,960 行**；该口径与初始 36,969 笔订单不同，注意不要混用两版统计。

---

## 3. Cancellation & Return Handling（已完成的探索与边界）

### 3.1 取消数据总体规模 `[已验证]`

`cancellation_lines` 从去重后的明细中选取：

```sql
WHERE invoice LIKE 'C%'
  AND quantity < 0
  AND price > 0
  AND customer_id IS NOT NULL
```

并将 `-quantity` 记为 `cancelled_quantity`，`-(quantity * price)` 记为正的 `cancellation_amount`。

| 指标 | 结果 |
|---|---:|
| 取消／退货明细数 | 18,446 |
| 取消 Invoice 数 | 7,901 |
| 涉及可识别客户 | 2,572 |
| 带符号取消金额 | −1,087,882.14 |

该金额绝对值约占初始候选正向金额的 **6.24%**，但**不能称为准确退款率**。

### 3.2 已人工确认的高金额完全抵消案例 `[已验证]`

| 原 Invoice | Customer ID | 原正向金额 | 对应取消 Invoice | 负向金额 | 间隔 |
|---|---:|---:|---|---:|---|
| `581483` | 16446 | +168,469.60 | `C581484` | −168,469.60 | 12 分钟 |
| `541431` | 12346 | +77,183.60 | `C541433` | −77,183.60 | 16 分钟 |

这两笔订单也是先前候选订单金额最高的两笔；它们证明了**“正向明细聚合正确”不等于“客户净消费正确”**。

### 3.3 自动匹配方法与实际结果 `[已验证]`

购买明细 `p` 与取消明细 `c` 的候选 JOIN 条件：

```sql
p.customer_id = c.customer_id
AND p.stock_code = c.stock_code
AND p.price = c.price
AND p.quantity = c.cancelled_quantity
AND p.invoice_date <= c.cancellation_date
```

此规则只覆盖**单条明细购买数量与取消数量完全相等**的候选情形；不覆盖一般的部分退货、多次拆分退货等复杂场景。原数据没有已验证的“取消明细 → 原订单明细”直接关联键。

全量 18,446 条取消明细匹配结果：

| 取消明细状态 | 行数 | 占取消明细比例 |
|---|---:|---:|
| 无候选匹配 | 12,196 | 66.1% |
| 单方向恰好 1 个候选 | 4,741 | 25.7% |
| 多个购买候选（Ambiguous） | 1,509 | 8.2% |

进一步发现**75 条购买明细**被**158 条单方向唯一候选取消明细**争用，最多同一购买明细对应 **4 条**候选取消明细。最终对全部候选配对同时施加“双向唯一”条件，得到 **4,539 组** `mutual_unique_cancellations`（按购买明细与取消明细 `row_id` 配对）。

基于这 4,539 组候选匹配，针对 **36,960 笔候选正向付费订单**的明细匹配状态：

| 订单匹配状态 | 订单数 |
|---|---:|
| No match | 34,668 |
| Partially matched | 2,108 |
| Fully matched（全部正向付费明细有双向唯一候选抵消） | 184 |

人工案例 `581483`、`541431` 均被自动识别为 `Fully matched`。**注意：这里的 Fully matched 是规则匹配状态，不是有外键证明的最终业务取消状态。**

### 3.4 当前真正用于建模的取消策略 `[当前约定]`

- **当前 Snapshot、RFM 和标签没有减去退款，也没有使用 `purchase_order_match_status` 过滤订单**。
- Baseline Target 明确定义为未来是否出现**候选正向付费订单事件**。
- 已完成的匹配 View 作为独立 Data Quality / 业务分析资产，供后续敏感性分析或改进。
- 若未来要排除取消订单，**匹配计算本身**也须按每个 Cutoff 限制可知数据，且需要防止错误的一对多匹配；不能直接将全历史匹配结果用于历史训练样本。

---

## 4. Snapshot、Observation Window 与 Prediction Window

### 4.1 预测问题的准确定义 `[当前约定，已实现]`

在预测时点 `cutoff_date = t`：

1. **Eligible population（预测对象）：** 在 `[t − 6 calendar months, t)` 内至少有 **1 笔候选正向付费订单**的客户。
2. **Observation Window（观察窗口）：** `[t − 6 calendar months, t)`，用于构造 RFM 特征。
3. **Prediction Window（预测窗口）：** `[t, t + 3 calendar months)`，用于判断未来是否出现至少一笔候选正向付费订单。
4. **Repurchase Label：** `repurchase = 1` 当且仅当该客户在 Prediction Window 内至少有 1 笔 `order_summary` 订单；否则为 `0`。

数学表达：

\[
y_{i,t} = \mathbf{1}\!\left(\exists\, o:\;o.customer\_id=i,\;t \le o.order\_date < t+3\text{ calendar months}\right)
\]

**边界规则：** 所有窗口**起点包含、终点不包含**；使用 MySQL `DATE_SUB/DATE_ADD(..., INTERVAL N MONTH)`，是**日历月**，并非严格固定的“过去 180 天 / 未来 90 天”。预测时点默认为所示日期 **00:00:00**。

这里的 `0` 表示**在可用数据中、按上述候选口径未观察到未来订单**，不能推断客户在现实世界中绝对没有购买；客户身份缺失或未记录交易也会影响观测。

### 4.2 六个已实现的 Snapshot 日期边界

| Cutoff Date | Observation Window（[起, 止)） | Prediction Window（[起, 止)） | 数据用途 |
|---|---|---|---|
| 2010-06-01 | 2009-12-01 — 2010-06-01 | 2010-06-01 — 2010-09-01 | Train |
| 2010-09-01 | 2010-03-01 — 2010-09-01 | 2010-09-01 — 2010-12-01 | Train |
| 2010-12-01 | 2010-06-01 — 2010-12-01 | 2010-12-01 — 2011-03-01 | Train |
| 2011-03-01 | 2010-09-01 — 2011-03-01 | 2011-03-01 — 2011-06-01 | Train |
| 2011-06-01 | 2010-12-01 — 2011-06-01 | 2011-06-01 — 2011-09-01 | Validation |
| 2011-09-01 | 2011-03-01 — 2011-09-01 | 2011-09-01 — 2011-12-01 | Test |

数据实际截至 **2011-12-09 12:50:00**，所以最后一个测试窗口到 2011-12-01（不含）的三个月标签范围是完整覆盖的。六组 Prediction Windows 相邻而不重叠；**Observation Windows 相互重叠**，且客户可重复出现在不同 Snapshot 中，这是设计的一部分。

### 4.3 特征与标签构造逻辑 `[已实现]`

使用按 Invoice × Customer 聚合并物化的 `order_summary`。其生成逻辑：

```sql
CREATE TABLE order_summary AS
SELECT
    invoice,
    customer_id,
    MIN(invoice_date) AS order_date,
    COUNT(*) AS paid_line_count,
    SUM(quantity) AS total_quantity,
    SUM(quantity * price) AS gross_amount
FROM positive_purchase_lines
GROUP BY invoice, customer_id;
```

多时点建模数据核心 SQL（与已执行逻辑一致；仅省略展示用的 `ORDER BY` 和 `LIMIT`）：

```sql
CREATE TABLE customer_snapshots_candidate AS
WITH cutoffs AS (
    SELECT DATE('2010-06-01') AS cutoff_date
    UNION ALL SELECT DATE('2010-09-01')
    UNION ALL SELECT DATE('2010-12-01')
    UNION ALL SELECT DATE('2011-03-01')
    UNION ALL SELECT DATE('2011-06-01')
    UNION ALL SELECT DATE('2011-09-01')
),
rfm AS (
    SELECT
        c.cutoff_date,
        o.customer_id,
        DATEDIFF(c.cutoff_date, MAX(o.order_date)) AS recency_days,
        COUNT(*) AS frequency_6m,
        SUM(o.gross_amount) AS monetary_6m
    FROM cutoffs AS c
    JOIN order_summary AS o
      ON o.order_date >= DATE_SUB(c.cutoff_date, INTERVAL 6 MONTH)
     AND o.order_date < c.cutoff_date
    GROUP BY c.cutoff_date, o.customer_id
),
future_customers AS (
    SELECT DISTINCT c.cutoff_date, o.customer_id
    FROM cutoffs AS c
    JOIN order_summary AS o
      ON o.order_date >= c.cutoff_date
     AND o.order_date < DATE_ADD(c.cutoff_date, INTERVAL 3 MONTH)
)
SELECT
    r.cutoff_date,
    r.customer_id,
    r.recency_days,
    r.frequency_6m,
    r.monetary_6m,
    CASE WHEN f.customer_id IS NOT NULL THEN 1 ELSE 0 END AS repurchase
FROM rfm AS r
LEFT JOIN future_customers AS f
  ON r.cutoff_date = f.cutoff_date
 AND r.customer_id = f.customer_id;
```

**解释：** `rfm` CTE 一行是 `(cutoff_date, customer_id)`；`future_customers` 使用 `DISTINCT`，避免未来多个订单导致 JOIN 重复；最终 `LEFT JOIN` 保留**没有未来购买的负例**。

**重要：** 已创建的 `customer_snapshots_candidate` 是 MySQL **实体表**，不会因为底层 View / 清洗规则改变而自动更新；重建前应做好依赖检查，避免盲目追加重复数据。上面 `CREATE TABLE` 语句用于说明可复现逻辑，不应在表已存在时再次直接执行。

---

## 5. RFM 特征定义（当前 V1）

所有特征只使用 `order_summary` 中 `order_date < cutoff_date` 的记录：

| 字段 | 数据类型（Python 已观察） | 计算规则 | 解释 / 限制 |
|---|---|---|---|
| `recency_days` | `int64` | `DATEDIFF(cutoff_date, MAX(order_date))` | 距观察期最近一笔候选正向订单的**日历天数**；只查过去 6 个月 |
| `frequency_6m` | `int64` | `COUNT(*)` | 观察期内候选正向**订单数**；因为 `order_summary` 每订单一行，不能按商品明细数理解 |
| `monetary_6m` | `float64`（读入 Pandas 后） | `SUM(gross_amount)` | 观察期内候选正向订单金额合计，**未净额扣退货** |

`customer_id` 是标识列，`cutoff_date` 是样本时点及划分列；两者**未被直接当作 V1 模型数值特征**。`repurchase` 为二分类目标。

**尚未实现的扩展特征 `[计划，不是当前产物]`：** 客户首次购买至 Cutoff 的历史资历、1/3 个月短期频率和金额、平均订单金额、购买间隔、活跃月份、产品种类、已知取消次数等。任何扩展特征必须满足 Point-in-Time Correctness。

---

## 6. 多时点样本结果与 Train / Validation / Test

### 6.1 六个预测时点的实际统计 `[已验证]`

| Cutoff Date | Total Samples | Positive (1) | Negative (0) | Positive Rate | Split |
|---|---:|---:|---:|---:|---|
| 2010-06-01 | 2,703 | 1,344 | 1,359 | 49.72% | Train |
| 2010-09-01 | 2,868 | 1,779 | 1,089 | 62.03% | Train |
| 2010-12-01 | 3,497 | 1,324 | 2,173 | 37.86% | Train |
| 2011-03-01 | 3,358 | 1,425 | 1,933 | 42.44% | Train |
| 2011-06-01 | 2,718 | 1,349 | 1,369 | 49.63% | Validation |
| 2011-09-01 | 2,813 | 1,701 | 1,112 | 60.47% | Test |
| **合计** | **17,957** | **8,922** | **9,035** | **49.69%** | — |

- 每个 Cutoff 已验证 `COUNT(*) = COUNT(DISTINCT customer_id)`，即**同一时点每客户最多一条记录**。
- 不同时点的 Positive Rate 差异明显，约 **37.86%–62.03%**。季节性可能是解释之一，但**没有完成因果或稳健季节性验证**。
- 历史全时段观察到的候选重复购买比例为 **72.39%（4,255 / 5,878）**；该指标不是任何一个 Snapshot 的标签正例率。

### 6.2 已执行的 Pandas 时间划分 `[已验证]`

```python
train_df = df[df["cutoff_date"] < "2011-06-01"].copy()
val_df = df[df["cutoff_date"] == "2011-06-01"].copy()
test_df = df[df["cutoff_date"] == "2011-09-01"].copy()
```

| Split | Cutoff Date 规则 | Shape | Positive / Negative |
|---|---|---|---|
| Train | `cutoff_date < 2011-06-01`（当前仅 4 个早期 Cutoff） | `(12426, 6)` | 5,872 / 6,554 |
| Validation | `cutoff_date == 2011-06-01` | `(2718, 6)` | 1,349 / 1,369 |
| Test | `cutoff_date == 2011-09-01` | `(2813, 6)` | 1,701 / 1,112 |

**为什么不随机切分：** 客户行为与预测日期有关；开发方案以较早 Cutoff 拟合模型、较晚 Cutoff 选择模型、最后的 Cutoff 独立验收。同一客户可跨 Cutoff 重复出现，不能把样本视为独立的不同客户；评估时需关注时间与客户相关性。

---

## 7. Data Leakage：已检查风险与预防原则

### 7.1 确认存在的跨 Cutoff 取消事件风险 `[已验证]`

在 `2011-06-01 00:00:00` 预测时点检查：

- 在 **2010-12-01 至 2011-06-01（不含）**期间购买；
- 对应的**双向唯一候选取消记录**在 **2011-06-01（含）以后**发生。

结果：**156 组候选配对、涉及 101 笔候选订单、86 位客户**（约占该时点 Eligible Customers 的 3.16%）。这说明若直接使用全历史匹配结果删除历史订单，可能把未来取消事件提前带入特征。

### 7.2 当前已经落实的预防措施 `[已实现]`

1. `RFM` 的明细筛选使用 `order_date < cutoff_date`，没有使用未来订单生成特征。
2. 标签只观察 `[cutoff_date, cutoff_date + 3 calendar months)`，不包含更晚的订单。
3. 候选取消匹配是独立探索资产；**未将全历史 `match_status` 输入 RFM 或标签**。
4. 按预测时点划分 Train / Validation / Test；**没有使用随机全表拆分**。
5. 首次 Logistic Regression 模型已使用 Scikit-learn `Pipeline(StandardScaler(), LogisticRegression(...))`，Scaler 在 Train 上拟合，再转换 Validation；**没有用 Validation/Test 的均值和标准差拟合 Scaler**。

### 7.3 后续必须遵守 / 尚未完成验证的事项

- `[待实现]` 若建造历史取消特征，需将 `cancellation_date < cutoff_date` 写入相应的特征查询，并在同一历史信息范围内完成候选匹配，不得使用全量历史后验匹配状态。
- `[待实现]` 新的类别编码、缺失值填充、特征筛选、概率校准等都应只在训练数据中 `fit`；Validation 仅用于开发决策，Test 作为最终独立评估。
- `[待核实]` 当前项目尚未完成对数据收录延迟、客户身份误配、同一工作表潜在重复、商品收费项目的系统性影响评估。
- `[重要]` 当前 Test 未用于模型调参；继续保持其独立性。若之后反复查看 Test 再修改模型，需重新设计真正独立的最终评估。

---

## 8. 已完成的数据产物、代码与文件

### 8.1 MySQL 对象（对话中已确认创建 / 查询成功）

| 对象 | 类型 | 用途 | 状态 |
|---|---|---|---|
| `transactions_raw` | TABLE | 1,067,371 行原始导入；含 `row_id` 主键 | `[已验证]` |
| `transactions_deduplicated` | VIEW | 去除 22,523 条跨年度重叠明细 | `[已验证]` |
| `paid_orders_candidate` | VIEW | 初始正向付费订单，排除 TEST001 前 | `[已验证]` |
| `positive_purchase_lines` | VIEW | 正数量、正价格、可识别客户、非 C 单；排除 `TEST001` | `[已验证]` |
| `cancellation_lines` | VIEW | 取消/退货明细及取消数量、金额的正向表示 | `[已验证]` |
| `mutual_unique_cancellations` | VIEW | 4,539 组双向唯一购买—取消候选配对 | `[已验证]` |
| `purchase_order_match_status` | VIEW | 36,960 笔订单的匹配状态 | `[已验证]` |
| `order_summary` | TABLE | 36,960 行物化候选订单数据，供后续快速分析 | `[已验证]` |
| `customer_snapshot_20110601_candidate` | VIEW | 单时点实验性 RFM + 标签（2,718 客户） | `[已验证]` |
| `customer_snapshots_candidate` | TABLE | 6 Cutoff、17,957 行完整候选样本 | `[已验证]` |

**提示：** 普通 MySQL View 不持久化查询结果；`order_summary` 和 `customer_snapshots_candidate` 是已持久化的**实体表**，源数据或业务规则改变后不会自动刷新。

### 8.2 文件与代码状态

| 项目资源 | 已知状态 |
|---|---|
| UCI 两个原始 Excel 工作表 | `[已使用]` 已导入并处理；本地原始文件的精确绝对路径 `[待核实]` |
| `data/interim/online_retail_ii_combined.parquet` | `[此前已确认成功保存 / 回读]` |
| MySQL 导入 Python 代码 | `[已实际运行]`，使用分批 `.to_sql(..., if_exists='append')`；具体 Notebook / 脚本文件名 `[待核实]` |
| `notebooks/01_data_understanding.ipynb` | 曾作为整理位置讨论；其当前实际文件路径及包含内容 `[待核实]` |
| `notebooks/02_modeling_dataset.ipynb` | 曾建议作为 Python 建模 Notebook 名称；运行了读取与建模代码，但**实际磁盘文件名及保存状态** `[待核实]` |
| `sql/01_create_tables.sql`、`sql/02_data_validation.sql`、`sql/03_create_dedup_view.sql` | 曾提出的 SQL 组织命名；**不能仅凭对话确认这些脚本已经完整落盘**，需在 GitHub 整理前检查 |
| `README.md` | 之前提到项目已有 README；当前内容及是否完整记录阶段 02 `[待核实]` |
| 本文 `stage_02_handoff_summary.md` | 本次交接文档；具体 GitHub 目标路径可采用 `docs/stage_02_handoff_summary.md` |

### 8.3 Pandas 读取与基础验证 `[已验证]`

```python
query = "SELECT * FROM customer_snapshots_candidate"
df = pd.read_sql(query, con=engine, parse_dates=["cutoff_date"])
```

- `df.shape == (17957, 6)`。
- Dtypes：`cutoff_date: datetime64[ns]`；`customer_id/int64`、`recency_days/int64`、`frequency_6m/int64`、`monetary_6m/float64`、`repurchase/int64`。
- 每列缺失值数量：**0**。
- `df.duplicated(subset=['cutoff_date','customer_id']).sum()`：**0**。
- 全部标签分布：`0 = 9,035`、`1 = 8,922`。

### 8.4 SQL 性能与运行环境方面的已知事实

- 创建复合索引 `idx_invoice_customer` 后，此前一个相关子查询耗时从约 **20 秒降至 2 秒**；此对比受缓存等因素影响，不属于受控 benchmark。
- `EXPLAIN` 对一次 Customer-Level 聚合显示 `type=index`，使用 `idx_purchase_matching`，估计扫描约 **992,587** 条索引记录；使用索引不代表一定是高效查找。
- 直接从明细 View 统计历史客户复购约 **90 秒**；创建 `order_summary` 实体表约 **90.485 秒**；之后从实体订单表统计约 **0.046 秒**。体现物化复用价值，但 SQL 内容与缓存条件并非完全相同，不应宣称严格 1,957 倍的受控性能提升。
- MySQL Workbench 曾遇 `Error Code: 2013`（约 30 秒断连）；SQL Editor 的读取超时设置改为 **300 秒**并完全重启 Workbench 后，`SELECT SLEEP(35)` 成功完成，后续长查询能够运行。

---

## 9. 向 Stage 03 · Machine Learning 交接

### 9.1 第一版模型输入契约（Schema Contract）

| Column | 角色 |
|---|---|
| `cutoff_date` | 时间切分、样本时点；V1 不直接进入模型 |
| `customer_id` | 客户标识；V1 不直接进入模型 |
| `recency_days` | V1 Feature |
| `frequency_6m` | V1 Feature |
| `monetary_6m` | V1 Feature |
| `repurchase` | Binary Target |

Python 中已按 cutoff 划分 `train_df`、`val_df`、`test_df`；Feature 列表为 `['recency_days', 'frequency_6m', 'monetary_6m']`。

### 9.2 已进入 Stage 03 的实际进度（供续接，不计作 Stage 02 EDA 结果）

- `[已验证]` 已训练 **Logistic Regression + StandardScaler** 的 RFM V1 Baseline，使用 `make_pipeline(StandardScaler(), LogisticRegression(max_iter=1000))`；只在 Train `.fit()`。
- `[已验证]` **Validation ROC-AUC = 0.7414**，这是首次实际运行结果，**不是 Test 指标**。
- `[尚未在该交接时完成]` 系数 / Odds Ratio 结果提取与解读；扩展特征、LightGBM、SHAP、最终 Test 评估均未报告可验证结果。

### 9.3 仍需解决的问题与优先级

| 优先级 | 问题 | 建议处理方式 / 验证原则 |
|---|---|---|
| P0 | **明确 Target 是候选正向购买事件，而非净保留购买** | 在 Notebook、README 和模型报告中统一称谓；不将预测解释为净销售或最终完成购买 |
| P0 | **Point-in-Time Correctness** | 所有新特征按各 Cutoff 截止；特别警惕取消记录、生命周期统计、预处理参数的时间泄漏 |
| P0 | **时间切分与 Test 独立性** | Train：前 4 Cutoff；Val：2011-06；Test：2011-09；开发过程中不使用 Test 选择超参数 |
| P1 | **取消 / 部分退货未可靠净额处理** | 先保持可复现的正向事件 Baseline；后续可做取消特征与敏感性分析，不强制匹配不确定退款 |
| P1 | **巨额订单与 Monetary 极端值** | 对 RFM 金额分布作诊断；在 Train 上评估 `log1p` / Robust Scaling 等方案，不能仅凭直觉删除 |
| P1 | **同一工作表重复明细未处理** | 记录局限，必要时量化对订单金额/数量的敏感性；不未经验证直接 `drop_duplicates()` |
| P1 | **现有特征较少** | V1 先固定 3 个 RFM；之后渐进加入历史行为、短期趋势、购买间隔、订单结构等，并验证增益 |
| P1 | **客户在多 Cutoff 重复出现 / 时间分布变化** | 检查时间段间性能与类别比例，必要时采用滚动时间验证；避免随机打乱后泄漏未来规律 |
| P2 | **商品与收费代码、国家、客户归属等数据语义** | 在添加相应特征前再做针对性业务检查 |
| P2 | **SQL 脚本与 Notebook 的 GitHub 可复现性** | 核对实际文件、将创建/校验 SQL 保存为脚本、增加数据处理顺序和版本说明；避免包含数据库密码 |
| P2 | **数据源币种 / 本地路径与环境版本** | 在 README 中注明核实来源；不随意猜测金额币种或本地文件路径 |

## 10. Reproducibility Checklist（交接验收清单）

- [x] 原始导入行数 = **1,067,371**。
- [x] 跨来源重叠仅排除重复的 **22,523** 行，剩余 = **1,044,848**。
- [x] 识别 `TEST001`，用于 `positive_purchase_lines` 过滤。
- [x] `order_summary` 已创建，**36,960** 行。
- [x] 候选取消数据、双向唯一匹配、订单匹配状态已统计并保留为独立分析资产。
- [x] 六个 Cutoff 的 RFM + Label 已物化为 `customer_snapshots_candidate`。
- [x] 每个 Cutoff 样本数、正例数与之前单独 SQL 统计一致。
- [x] Python 加载 **17,957 × 6**，无缺失、无 `(cutoff_date, customer_id)` 重复。
- [x] 时间切分样本数：**12,426 / 2,718 / 2,813**。
- [x] Stage 03 首次 Validation ROC-AUC = **0.7414**（仅作进度交接）。
- [ ] **待核实**：所有 SQL `.sql` 文件是否已经实际保存、能否按依赖顺序重建全部对象。
- [ ] **待核实**：Jupyter Notebook 的实际文件名与最终 GitHub 路径。
- [ ] **待完成**：Model Card / README 中的目标口径、退货限制、时间划分、验证与测试结果的正式说明。
- [ ] **待完成**：扩展特征、模型诊断、LightGBM、SHAP，以及未使用 Test 调参前提下的最终评估。

---

**结论：** Stage 02 已产出经过实际核对的 **17,957 行候选复购预测样本**，并完成关键的数据质量与泄漏风险调查。Stage 03 应继续使用这份明确的**正向购买事件**口径建立可解释 Baseline、扩展特征并开展严格的按时间验证；如果将任务升级为“预测最终保留购买”，必须重新定义退款归属、特征及标签，不能把当前候选数据直接改名为已净额清洗数据。
