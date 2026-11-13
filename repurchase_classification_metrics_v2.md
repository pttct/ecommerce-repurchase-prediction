# Classification Metrics Cheat Sheet

> **项目**：E-commerce Customer Repurchase Prediction & Analytics  
> **任务**：Task 49–50 · Model Evaluation  
> **标签定义**：`1 = 未来复购（Positive）`；`0 = 未来未复购（Negative）`

## 1. Confusion Matrix（混淆矩阵）

以下按照 **scikit-learn 的默认排布**：行是真实标签（Actual），列是预测标签（Predicted）。

| Actual \ Predicted | 1：预测复购 | 0：预测未复购 |
|:--|:--:|:--:|
| **1：实际复购** | **TP**（True Positive，正确命中） | **FN**（False Negative，漏报） |
| **0：实际未复购** | **FP**（False Positive，误报） | **TN**（True Negative，正确排除） |

**记忆：** `True / False` 表示预测**对 / 错**；`Positive / Negative` 表示模型**预测为 1 / 0**。

- **TP**：预测复购，实际复购。
- **FP**：预测复购，实际没复购（误报）。
- **FN**：预测没复购，实际复购（漏报）。
- **TN**：预测没复购，实际没复购。

**四个常用分母：**

| 分母 | 代表什么 |
|---|---|
| `TP + FP` | 所有**预测为正例**的人（Predicted Positive） |
| `TP + FN` | 所有**实际为正例**的人（Actual Positive） |
| `TN + FP` | 所有**实际为负例**的人（Actual Negative） |
| `TN + FN` | 所有**预测为负例**的人（Predicted Negative） |

## 2. 六个必会指标

| 指标（别名） | 公式 | 一句话理解 |
|---|---|---|
| **Accuracy** | $\frac{TP+TN}{TP+TN+FP+FN}$ | 所有样本中，预测正确的比例 |
| **Precision / PPV** | $\frac{TP}{TP+FP}$ | **预测复购**的人中，真的复购多少？ |
| **Recall / TPR / Sensitivity** | $\frac{TP}{TP+FN}$ | **实际复购**的人中，找到了多少？ |
| **Specificity / TNR** | $\frac{TN}{TN+FP}$ | **实际未复购**的人中，正确排除了多少？ |
| **FPR（False Positive Rate）** | $\frac{FP}{FP+TN}$ | **实际未复购**的人中，误报了多少？ |
| **FNR（False Negative Rate）** | $\frac{FN}{FN+TP}$ | **实际复购**的人中，漏掉了多少？ |

互补关系：

$$
\boxed{\mathrm{TPR}+\mathrm{FNR}=1},\qquad
\boxed{\mathrm{TNR}+\mathrm{FPR}=1}
$$

> **最简单的记忆方法：** Precision 的分母是“**预测**为正”；Recall / TPR 的分母是“**实际**为正”；TNR / FPR 的分母是“**实际**为负”。

## 3. 其他常见指标

| 指标 | 公式 | 用途 |
|---|---|---|
| **F1-Score** | $\frac{2 \cdot Precision \cdot Recall}{Precision+Recall}=\frac{2TP}{2TP+FP+FN}$ | Precision 与 Recall 的调和平均 |
| **NPV（Negative Predictive Value）** | $\frac{TN}{TN+FN}$ | 预测未复购的人中，真的未复购多少？ |
| **FDR（False Discovery Rate）** | $\frac{FP}{TP+FP}$ | 预测复购的人中，误报多少？ |
| **FOR（False Omission Rate）** | $\frac{FN}{FN+TN}$ | 预测未复购的人中，漏报多少？ |
| **Balanced Accuracy** | $\frac{TPR+TNR}{2}$ | 正负类识别能力的平均 |
| **Positive Rate / Prevalence** | $\frac{TP+FN}{N}$ | 样本中实际复购客户的比例 |

其中 $N=TP+TN+FP+FN$。另有：$FDR=1-Precision$，$FOR=1-NPV$。

## 4. 一组手算例子

假设在 **100 位客户**中：`TP=40`、`FP=20`、`FN=10`、`TN=30`。

| 指标 | 代入计算 | 结果 |
|---|---|---:|
| Accuracy | $(40+30)/100$ | **70.0%** |
| Precision | $40/(40+20)$ | **66.7%** |
| Recall / TPR | $40/(40+10)$ | **80.0%** |
| Specificity / TNR | $30/(30+20)$ | **60.0%** |
| FPR | $20/(20+30)$ | **40.0%** |
| FNR | $10/(10+40)$ | **20.0%** |
| F1 | $2\times 40/(2\times40+20+10)$ | **72.7%** |
| NPV | $30/(30+10)$ | **75.0%** |
| Balanced Accuracy | $(80\%+60\%)/2$ | **70.0%** |

## 5. ROC-AUC vs Average Precision（AP）

| 指标 | 曲线坐标 | 要点 |
|---|---|---|
| **ROC-AUC** | 横轴 FPR；纵轴 TPR（Recall） | 衡量正例分数高于负例分数的排序能力；随机模型基准通常为 0.5 |
| **PR Curve / AP** | 横轴 Recall；纵轴 Precision | 更直接反映识别正例时的 Precision–Recall 权衡；随机排序的 AP 基准近似为正例比例 |

**精确定义：** `average_precision_score` 计算的是 **Average Precision（AP）**，采用按 Recall 增量加权的 Precision 汇总；它与使用梯形积分得到的 PR-AUC **不完全相同**。

ROC-AUC 和 AP 使用**预测概率或连续分数**，不能只凭某一个阈值对应的一组 TP / FP / FN / TN 算出。

### 当前项目的 Validation 结果

- **Validation samples**：2,718
- **Positive rate**：0.4963（49.63%）
- **ROC-AUC**：0.7414
- **Average Precision**：0.7641
- **Baseline**：`StandardScaler + LogisticRegression`

**解读：** 复购标签在 Validation 中基本均衡；AP 高于随机排序约 0.4963 的参考水平。这些数值并不直接告诉我们阈值设为 0.5 时的 Precision、Recall 或 Confusion Matrix。

## 6. scikit-learn 常用代码

```python
import numpy as np
from sklearn.metrics import (
    confusion_matrix,
    accuracy_score,
    precision_score,
    recall_score,
    f1_score,
    balanced_accuracy_score,
    roc_auc_score,
    average_precision_score,
)

# Pipeline 接收未手工标准化的 X_val
proba = baseline.predict_proba(X_val)[:, 1]
threshold = 0.50
pred = (proba >= threshold).astype(int)

# 注意：sklearn 的二维混淆矩阵是 行=Actual，列=Predicted
# 对于 labels=[0, 1]，顺序为 [[TN, FP], [FN, TP]]
tn, fp, fn, tp = confusion_matrix(
    y_val, pred, labels=[0, 1]
).ravel()

print(f"TN={tn}, FP={fp}, FN={fn}, TP={tp}")
print("Accuracy:", accuracy_score(y_val, pred))
print("Precision:", precision_score(y_val, pred, zero_division=0))
print("Recall / TPR:", recall_score(y_val, pred, zero_division=0))
print("F1:", f1_score(y_val, pred, zero_division=0))
print("Specificity / TNR:", tn / (tn + fp) if tn + fp else np.nan)
print("FPR:", fp / (fp + tn) if fp + tn else np.nan)
print("FNR:", fn / (fn + tp) if fn + tp else np.nan)
print("Balanced Accuracy:", balanced_accuracy_score(y_val, pred))
print("ROC-AUC:", roc_auc_score(y_val, proba))
print("Average Precision:", average_precision_score(y_val, proba))
```

## 7. 面试与业务判断

- **优惠券投放预算有限，误报成本高？** 重点观察 **Precision**（同时考虑营销 uplift、券成本与收益）。
- **希望尽量发现潜在复购客户？** 重点观察 **Recall**。
- **类别不均衡？** 不要只看 Accuracy；结合混淆矩阵、PR / AP 和业务成本。
- **阈值 0.5 是固定的吗？** 不是。阈值改变会影响 TP、FP、FN、TN，进而改变 Precision / Recall；应只在训练/验证数据上选择阈值，并在最终 Test 上做一次独立评估。
- **高 AUC 就能直接部署吗？** 不能。还需考虑概率校准、时间稳定性、业务效果与数据漂移。

---

*项目学习笔记 · 公式与示例便于复习；当前验证指标来自实际实验，不代表最终测试集表现。*
