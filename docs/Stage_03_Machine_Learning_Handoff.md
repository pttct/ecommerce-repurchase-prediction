# Stage 03 Handoff Summary — Machine Learning

**Project:** E-commerce Customer Repurchase Prediction & Analytics  
**Data:** UCI Online Retail II  
**阶段：** 03 · Machine Learning → 04 · Code Review & GitHub  
**记录日期：** 2026-11-12  
**状态：** 建模、历史验证与一次最终测试已完成；代码审查、可复现性整理及最终模型解释图尚待完成。

> **证据边界**：本文件记录的是 Stage 03 对话中用户实际运行并回报的数值与代码设计。未直接审查完整 Notebook、MySQL schema、SQL 生成脚本及 Stage 02 Handoff，因此对源数据去重、部分字段定义等不另行推断；需要回到源码确认的项目均标注「待核实」。不要将本总结当成源码审计已经通过的证明。

## 1. 项目目标和业务定义

**研究问题**：基于客户截至某历史时点已发生的购买行为，预测其在接下来三个月内是否再次购买。

- 数据粒度：`(customer_id, cutoff_date)`（Customer–Snapshot）。同一客户可在不同日期产生不同样本。
- Observation Window：`[cutoff_date - INTERVAL 6 MONTH, cutoff_date)`；六个**日历月**。
- Prediction Window：`[cutoff_date, cutoff_date + INTERVAL 3 MONTH)`；三个**日历月**。
- `repurchase_label = 1`：该预测窗口中存在至少一笔符合项目定义的有效正向购买订单；否则为 `0`。
- 源数据按**有效正向购买**口径处理，尚未完全将退款/取消单净额配对抵扣。因此它是 transaction-based positive-purchase repurchase prediction，而非净成交额、客户增量价值或营销干预 uplift 模型。
- 模型预测的是**自然复购倾向**，不能通过 Precision@K 或 Lift@K 直接宣称营销活动因其而产生增量销售。

### 数据来源

使用 Online Retail II 的两个年度工作表：`Year 2009-2010` 和 `Year 2010-2011`，分别大体覆盖 2009-12 至 2010-12、2010-12 至 2011-12。2009 年 1–11 月没有该数据集记录。此前对话提及合并原始 1,067,371 行，以及去重 22,523 行、剩余 1,044,848 行；**这些精确的去重数字尚未在 Stage 03 重新独立核验，须在 Stage 02 源码确认**，尤其应检查两个来源在 2010 年 12 月的时间重叠。

## 2. Snapshot 设计与分割

| Split | Snapshot cutoff dates | Rows | Unique customers | Distinct snapshot dates | Duplicate `(customer_id, cutoff_date)` |
|:--|:--|--:|--:|--:|--:|
| Train | 2010-06-01, 2010-09-01, 2010-12-01, 2011-03-01 | 12,426 | 4,537 | 4 | 0 |
| Validation | 2011-06-01 | 2,718 | 2,718 | 1 | 0 |
| Test | 2011-09-01 | 2,813 | 2,813 | 1 | 0 |
| **Total** | 6 snapshots | **17,957** | 不应简单相加 | 6 | **0** |

训练样本按 Snapshot 的分布：

| Train snapshot | Rows |
|:--|--:|
| 2010-06-01 | 2,703 |
| 2010-09-01 | 2,868 |
| 2010-12-01 | 3,497 |
| 2011-03-01 | 3,358 |
| **合计** | **12,426** |

训练最后一批 Snapshot 的预测窗口是 `[2011-03-01, 2011-06-01)`，在 Validation 截止日之前完整结束。Validation 的标签窗口是 `[2011-06-01, 2011-09-01)`，在 Test 截止日之前结束。使用时间顺序划分而非随机划分；同一客户跨快照重复并非自动构成泄漏，但样本间存在依赖性。

**各观察期正例比例**（Stage 03 独立复算的标签结果）：

| cutoff_date | Positive rate |
|:--|--:|
| 2010-06-01 | 0.4972 |
| 2010-09-01 | 0.6203 |
| 2010-12-01 | 0.3786 |
| 2011-03-01 | 0.4244 |
| 2011-06-01 | 0.4963 |
| 2011-09-01 (Test) | 0.6047 |

季度之间的 Target Prevalence 差异显著，跨期 AP 不能仅看绝对值，须同时参考各期正例比例。上述变化可能与季节性或样本组成有关，原因**未得到识别**。

## 3. Feature Engineering：V1 和 V2

### 3.1 V1（7 features）

| Feature | 含义 / 来源 |
|:--|:--|
| `recency_days` | 距最近一次有效购买的天数（RFM） |
| `frequency_6m` | 观察期购买频次（RFM） |
| `monetary_6m` | 观察期累计消费金额（RFM） |
| `orders_last_30d` | 截止日前 30 天订单数（SQL） |
| `orders_last_90d` | 截止日前 90 天订单数（SQL） |
| `avg_order_value_6m` | 观察期平均订单金额（SQL） |
| `unique_products_6m` | 观察期购买的不同商品数（SQL） |

SQL 特征源表/输出表在实验中使用：`customer_snapshots_candidate`、`order_summary`、`positive_purchase_lines`、`snapshot_behavioral_features`。合并键为 `customer_id + cutoff_date`，使用 one-to-one merge 验证；17,957 条特征行均匹配，`orders_last_30d <= orders_last_90d`，产品数为零和 AOV 缺失数均为 0。

### 3.2 V2（新增 6 features，总计 13）

| Feature | 含义 / 注意事项 |
|:--|:--|
| `active_months_6m` | 过去 6 个日历月窗口中出现购买的不同自然月数 |
| `avg_days_between_orders` | 按订单日期排序的相邻订单间隔平均天数 |
| `std_days_between_orders` | 相邻订单间隔的总体标准差 |
| `has_interorder_gap` | 是否至少两笔可计算间隔的订单；用来区分填补零值与真实间隔 |
| `orders_prev_90d` | `[cutoff_date-180 days, cutoff_date-90 days)` 的订单数，仍受 6 日历月观察窗口过滤 |
| `order_change_90d` | 最近 90 日订单数减此前 90 日订单数；可以为负数 |

SQL 输出表：`snapshot_behavioral_features_v2`。`recent_90_check` 仅作一致性检查，不进入模型。V2 检查报告：总行数 17,957、唯一键 17,957、与 V1 的最近 90 天订单数不一致 0、零活跃月份 0、无效订单间隔 0、错误 gap 标识 0。

**特征口径说明：** `6 MONTH`（日历月）不严格等于 `180 DAY`；在 V2 的趋势窗口中两种边界共存，务必保留代码注释并在 04 阶段核对。`order_change_90d` 可为负，不允许直接 `log1p`。

### 3.3 分布与变换

原始 Train skewness：`recency_days = 0.595`、`frequency_6m = 9.361`、`monetary_6m = 19.075`。Frequency 与 Monetary 使用 `np.log1p` 后偏度约 1.536 与 0.300；Recency 保持不变。Logistic Regression 使用 `StandardScaler`；树模型使用原始数值，不需要标准化。

- 原始 Frequency–Monetary Pearson r = 0.634；变换后 r = 0.753。
- `active_last_30d = 1(recency_days <= 30)` 的训练占比 34.4117%，加入后 Validation AUC 从 0.7535 变为 0.7534、AP 从 0.7739 变为 0.7738，**未保留**。
- 回归系数比较（特征已标准化，系数不可跨变换直接比较绝对效应）：

| Feature | Original LR coef | Log LR coef |
|:--|--:|--:|
| Recency | -0.201422 | -0.139562 |
| Frequency | +1.646953 | +0.694815 |
| Monetary | +0.166671 | +0.307744 |

## 4. 模型实验与模型选择

### 4.1 原始 Baseline 与 V1

| Model / setting | Validation ROC-AUC | Validation AP |
|:--|--:|--:|
| Original RFM Logistic Regression (StandardScaler) | 0.7414 | 0.7641 |
| Log-transformed RFM Logistic Regression | 0.7535 | 0.7739 |
| Expanded LR, 7 features | 0.7551 | 0.7771 |
| Random Forest V1 (initial) | 0.7411 | 0.7706 |
| LightGBM V1 (initial) | 0.7423 | 0.7710 |
| Random Forest V1 (regularized) | 0.7573 | 0.7815 |
| LightGBM V1 (regularized) | 0.7546 | 0.7797 |
| CatBoost V1 (initial conservative config) | 0.7572 | 0.7823 |

初始树模型 Train–Validation AUC gap：RF +0.1172，LightGBM +0.0520。降低复杂度后，RF -0.0060、LightGBM -0.0067，Validation 表现提高。负 gap 不代表泛化完美，不同时期数据分布可能不同。

实验中 RF regularized 配置：

```python
RandomForestClassifier(
    n_estimators=300,
    max_depth=6,
    min_samples_leaf=30,
    random_state=42,
    n_jobs=-1,
)
```

用于 V1/V2 的其他配置：LightGBM regularized 使用 `n_estimators=150`, `learning_rate=0.05`, `num_leaves=7`, `max_depth=4`, `min_child_samples=100`, `reg_lambda=5.0`, `random_state=42`；CatBoost 使用 `iterations=400`, `depth=4`, `learning_rate=0.03`, `l2_leaf_reg=10`, `loss_function='Logloss'`, `random_seed=42`。完整配置请与 Notebook 核对。

### 4.2 V1 → V2 Feature Group Ablation

同一 Train/Validation、相同模型配置，V2 增加 6 个特征（共 13）。

| Model | V1 AUC | V2 AUC | V1 AP | V2 AP |
|:--|--:|--:|--:|--:|
| Logistic Regression | 0.7551 | 0.7538 | 0.7771 | 0.7835 |
| Random Forest | 0.7573 | **0.7587** | 0.7815 | 0.7871 |
| LightGBM | 0.7546 | 0.7570 | 0.7797 | 0.7861 |
| CatBoost | 0.7572 | **0.7588** | 0.7823 | **0.7876** |

增加 V2 特征后，四种模型 AP 均提高，AUC 改变较小；不能据此声称具有统计显著提升。单个 Validation Snapshot 被多次用于实验选择，存在 validation overfitting 风险。

### 4.3 Expanding-window Temporal Validation（诊断性）

| Validation Snapshot | Train rows | Val rows | RF V2 AUC / AP | CatBoost V2 AUC / AP |
|:--|--:|--:|:--|:--|
| 2010-12-01 | 5,571 | 3,497 | 0.7526 / 0.6939 | 0.7541 / 0.6953 |
| 2011-03-01 | 9,068 | 3,358 | 0.7505 / 0.7338 | 0.7450 / 0.7276 |
| 2011-06-01 | 12,426 | 2,718 | 0.7587 / 0.7871 | 0.7588 / 0.7876 |

训练时使用此前快照，且每一批训练标签的预测窗口均在当前验证 cutoff 前结束。模型在这三个验证日期的 AUC 约 0.745–0.759，说明历史表现未出现巨大波动；**这些并非独立的全新测试集**，且不能证明长期稳健。按验证 AUC、历史表现和模型选择简单程度，最终选择 **Random Forest V2**；CatBoost V2 作为对照，其性能与 RF 非常接近。

## 5. Interpretability 与 Calibration：已完成的范围

### 5.1 已运行的 RF V1（7 特征）解释

Permutation Importance（Validation ROC-AUC 平均下降，5 次置换）：

| Feature | Mean | Std |
|:--|--:|--:|
| `frequency_6m` | 0.0360 | 0.0063 |
| `monetary_6m` | 0.0304 | 0.0065 |
| `recency_days` | 0.0057 | 0.0022 |
| `unique_products_6m` | 0.0053 | 0.0015 |
| `orders_last_90d` | 0.0041 | 0.0027 |
| `avg_order_value_6m` | 0.0013 | 0.0012 |
| `orders_last_30d` | 0.0000 | 0.0001 |

还运行过 RF V1 的 SHAP beeswarm（500 个 Validation 样本）和两个客户的 Waterfall Plot，预测概率示例约为 97.8%、16.3%，解释器 base value 约为 47.3%。

**关键限制：上述置换重要性、SHAP 图均属于 7-feature RF V1，不是最终 13-feature RF V2。** 04 阶段应基于 `v2_models['Random Forest']` 与对应 13-feature Validation 数据重新制作 V2 SHAP / Permutation 图片；或者明确注明 V1 解释是历史实验，**不得误标为最终模型解释**。

### 5.2 Calibration

V1 的 Validation Brier Score：Expanded LR = 0.2006，RF V1 = 0.1993；CatBoost V1 = 0.1992。已生成 LR 与 RF V1 的 Calibration Curve。**没有记录 RF V2 的 Validation Brier，因此不应把 0.1993 与 RF V2 的最终 Test Brier 直接作为同一模型协议下的校准前后对比。**

## 6. 标签一致性与数据泄漏审核

独立以 `order_summary` 对 cutoff 之后三日历月的订单执行 SQL `EXISTS` 重新计算 Train+Validation 标签。创建 `(customer_id, order_date)` 复合索引后查询完成，避免无索引相关子查询过慢。

| Audit | Observed |
|:--|--:|
| Train + Validation rows | 15,144 |
| Unmatched rows | 0 |
| Label mismatches | **0** |

已验证/已有证据：

1. `(customer_id, cutoff_date)` 无重复，特征 SQL 仅查询 `order_date < cutoff_date` 的数据。
2. Label SQL 重新计算与既有标签逐样本一致。
3. Train → Validation → Test 的标签窗口按上述设计相邻而不重叠。
4. 扩展特征用 `validate='one_to_one'` 合并，未改变样本量。
5. Test labels 直到最终评估前未用于模型选择。

**04 阶段仍需审查源码**：

- Stage 02 原始两份年度数据在 2010-12 重叠的去重策略、去重 key 和记录数。
- 是否有根据未来交易筛选当前 snapshot 客户的步骤（样本选择泄漏）；候选客户必须由 cutoff 前可见历史确定。
- SQL 中 `order_summary` 与商品明细的订单/金额/退货口径是否与标签定义一致。
- Observation、Label 的准确左闭右开日期边界，是否存在跨期订单对同一客户的重复或后验信息使用。
- SQL V2 `6 MONTH` 与 `180 DAY` 的窗口细微差异是否按预期记录。
- 是否保留了随时可复算上述审计结果的 SQL/Notebook。

**审计结论：** 已通过数据粒度、部分时间边界与标签一致性检查；这**不是**所有潜在泄漏均已排除的证明。

## 7. Final Model：锁定方案与 Held-out Test

- **选定主模型**：Random Forest V2，13 特征，正则化配置同第 4 节。
- **最终训练协议**：合并原 Train 12,426 + Validation 2,718 = **15,144 条 customer-snapshot 记录**，使用 `clone(rf_tuned)` 按相同超参数重新拟合。
- **最终测试**：2011-09-01 Snapshot，**2,813** 条记录。没有利用最终测试指标再次修改模型配置。
- **未冻结分类阈值**：没有将 `0.3 / 0.4 / 0.5` 等此前 LR 的阈值试验当成最终 RF 的默认业务方案；业务部分直接采用事先列出的 Top 10/20/30% 排序评估。

### 真正运行得到的 Test 指标

| Metric | Final RF V2 · Test |
|:--|--:|
| Positive rate | **0.6047** |
| ROC-AUC | **0.7393** |
| Average Precision | **0.8276** |
| Brier Score | **0.2154** |

Test AUC 较 V2 RF Development Validation AUC 0.7587 低约 0.0194。注意两次模型的训练样本量不同（验证阶段只用 Train；最终测试阶段合并 Train+Validation），而且目标分布不同，所以不能完全把该差异归因于时间漂移。Test AP 更高，部分反映 Test 正例比例 60.47% 高于 Validation 的 49.63%；随机排序 AP 基准分别约为 0.6047 和 0.4963。性能应如实报告，而非继续针对 Test 调参。

## 8. Business Evaluation：Top-K / Lift

根据 Final RF V2 的 Test 预测概率从高到低排序，分析预先指定的 Top 10%、20%、30%：

| Top fraction | Selected snapshots | Precision@K | Recall@K | Lift@K |
|:--|--:|--:|--:|--:|
| Top 10% | 282 | **0.9716** | 0.1611 | **1.6068** |
| Top 20% | 563 | 0.9183 | 0.3039 | 1.5186 |
| Top 30% | 844 | 0.8637 | 0.4286 | 1.4284 |

`Precision@K = positives_among_top_K / K`；`Recall@K = positives_among_top_K / all_positives`；`Lift@K = Precision@K / overall_positive_rate`。

**业务表述边界：** Top 10% 的实际复购率 97.16%，是测试期整体复购率 60.47% 的约 1.61 倍，说明模型具有客户优先级排序价值。**不代表优惠券、广告或营销触达使这些客户复购，也不等于 1.61 倍营销 ROI**。要评估增量效益还需要 A/B Test、Uplift/Causal Inference 或营销成本与收益资料。

## 9. 主要 Python / SQL 变量与产物（以当前 Notebook 为准）

### Python 关键变量

```text
baseline                # Original StandardScaler + LogisticRegression Pipeline
log_baseline            # log-RFM LR
expanded_lr             # V1 expanded LR (7 features)
rf_tuned                # V1 regularized RF; also source for V2 final hyperparameters
lgbm_tuned              # V1 regularized LightGBM
cat_model               # V1 CatBoost
train_df / val_df / test_df
train_new / val_new / test_new   # V1 expanded features
train_v2 / val_v2 / test_v2     # V2 expanded features
expanded_features       # V1 7 feature names
features_v2             # V2 13 feature names
X_train_v2_tree / X_val_v2_tree
v2_models               # validation-stage fitted V2 models
ablation_df             # V1 vs V2 metrics
cv_df                   # historical rolling/expanding validation
label_check / audit_df  # label consistency checks
final_rf                # final fitted RF on Train + Validation
X_test_v2_tree / test_proba
lift_df                 # test Top-K analysis
```

### SQL 表与数据资产

```text
transactions_raw                # 原始导入交易表（02）
order_summary                   # 有效订单级数据（核实 schema）
positive_purchase_lines         # 有效商品交易明细（核实 schema）
customer_snapshots_candidate    # 17,957 行 customer-snapshot 候选集
snapshot_behavioral_features    # V1 SQL 特征
snapshot_behavioral_features_v2 # V2 SQL 特征
idx_customer_order_date         # on order_summary(customer_id, order_date)
```

以上是对话中曾使用的对象名称；是否实际保存在某个脚本或 CSV/Parquet，以及源码的规范化位置，**04 阶段需通过文件系统核实**。

## 10. Stage 04 Code Review & GitHub：明确待办

### P0：可复现性与数据契约（必须）

- [ ] 在新 kernel 中从头 `Run All`，没有未定义变量、Cell 执行顺序依赖；记录每个产物实际生成的路径。
- [ ] 审查 Stage 02 SQL 清洗、重叠去重、Snapshot eligible population、Label、时间边界，保证 README 与源码一致。
- [ ] 核对 13 个 V2 feature 的 SQL 定义、单位、空值填补与 join keys；自动检查行数、键唯一性、负值、缺失、时窗。
- [ ] 固定 Python/MySQL/package 版本和随机种子；补 `requirements.txt`（或 lock file），不凭猜测填写版本。
- [ ] 检查不把完整数据集、敏感标识符、密码、数据库账号/本地绝对路径提交 GitHub；使用 `.gitignore` 和配置模板。
- [ ] 固化最终模型训练/保存及评价产物（如 `joblib`/CSV/图像），记录 final test 协议，防止重测选择。

### P1：报告与模型说明（强烈建议）

- [ ] 重新制作 **13-feature RF V2** 的 Permutation Importance 和 SHAP 图，标明使用哪一个模型、样本划分。
- [ ] 用实验结果文件或独立表格自动生成 README 的性能表，避免手抄数值错误。
- [ ] 图表：时点正样本率、V1/V2 ablation、时间外 ROC-AUC、最终测试 Top-K Lift/Gains。
- [ ] README 解释：业务目标、数据口径、Observation/Prediction Window、SQL → Python 处理、时间划分、模型与业务指标、局限性。
- [ ] 可选：最终模型的 Test Calibration Curve 只作锁定模型的诊断，不用来继续调整模型。

### P2：求职交付

- [ ] 准备 2–3 条可核实的英文简历项目 bullet。
- [ ] 编写面试项目讲解：为什么多 Snapshot、为什么 Temporal Split、为什么 RF 而非 CatBoost、为什么 Test AUC 下降、为什么 Lift ≠ Uplift。
- [ ] 将完整项目作为 V1 Portfolio 发布，另开 `Technical Interview Preparation` / `Project Mock Interview` 对话复习基础。

## 11. 推荐 GitHub 目录（建议，不代表已经实现）

```text
E-commerce-Repurchase-Prediction/
├── README.md
├── requirements.txt
├── .gitignore
├── sql/
│   ├── 01_cleaning_and_order_summary.sql
│   ├── 02_snapshots_and_labels.sql
│   ├── 03_behavioral_features_v1.sql
│   └── 04_behavioral_features_v2.sql
├── notebooks/
│   ├── 01_eda.ipynb
│   ├── 02_modeling.ipynb
│   └── 03_evaluation.ipynb
├── src/                    # 仅在确有必要时抽取复用逻辑
├── figures/
├── docs/
│   ├── 02_data_preparation_summary.md
│   └── 03_machine_learning_handoff.md
└── data/
    └── README.md          # 说明公开数据获取与构建方式，不提交原始大文件
```

## 12. 04 阶段开工建议

1. 先查看实际 VS Code 项目树、SQL 脚本、Notebook 和 Stage 02 Handoff，核对是否与本总结一致。
2. 优先保证从 SQL 数据准备到模型评估可重复运行，并解决任何意外的时间泄漏和命名问题。
3. 重新生成 V2 的解释性图片与自动化结果表，再完成 README / GitHub。
4. 不再以 Test Set 为依据重调参。若发现重大数据处理错误，需要记录它、修复整个流程并如实重报结果，不能仍把后验重测称为首次完全盲测。

**交接结论：** 核心建模与一次最终 Out-of-Time Test 已完成。项目当前最需要的是**可复现性、数据边界核验、最终模型解释图更新，以及高质量 GitHub 说明**，而不是继续堆叠算法。
