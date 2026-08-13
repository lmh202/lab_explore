# Gemma 轮次（nvidia/Gemma-4-26B-A4B-NVFP4，262144上下文 + 原版 pi 0.84.1）bad case 记录

## tabular-playground-series-may-2022 — completed，0.91939 vs bronze 0.99818（越高越好）
特征工程只做了dtype嗅探：
```python
for col in cols:
    if df[col].dtype == 'object': cat_cols.append(col)
```
只找到f_27（10字符字符串，67万/80万行唯一），直接LabelEncode成一个有序整数喂给CatBoost，没拆字符、没做任何数值交互特征——尽管task描述明确点出本题关键是"挖掘特征间的交互关系"。11次工具调用里零EDA、零误差回溯，51分钟收工（6小时预算的14%）。OOF AUC 0.9186≈线上0.91939，验证是诚实的，天花板卡在特征表达能力，不是过拟合。

## ventilator-pressure-prediction — invalid_submission，host validator拒绝
```python
df = df.sort_values(['breath_id', 'time_step'])
...
submission = pd.DataFrame({'id': test['id'], 'pressure': test_preds})
```
`create_features()`把排序后的结果覆盖回`test`，submission又直接用这个被重排过的`test['id']`，导致提交行序和sample_submission不一致。host报错："ID/order mismatch at CSV row 2: expected '1', got '500401'"。是脚本执行错误，不是模型输出内容错误——ID与预测值仍然对应，只是行序检查没通过。

## chaii-hindi-and-tamil-question-answering — completed，0.08204 vs bronze 0.73725（越高越好）
```python
matching_train_rows = train[train["context"] == test_context]
test.loc[i, "predicted_answer"] = matching_train_rows.iloc[most_similar_idx]["answer_text"]
```
32次工具调用全程没出现`torch`/`transformers`/`AutoModel`，从未微调任何模型，只用TF-IDF+余弦相似度检索最相似的训练样本、直接照抄其answer_text——本质是"抄答案"而非抽取式QA。模型思考记录里明确写出正确做法（微调XLM-R/mBERT）又主动放弃，理由是"时间有限"，但实际只用了360分钟预算里的17分钟（4.8%）。自测Jaccard 0.106与线上0.082吻合，这就是该方法的真实上限。

## text-normalization-challenge-english-language — completed，0.99059 vs bronze 0.99038（越高越好）**，唯一拿牌case**
18次工具调用，8分钟完成，bronze_medal=true。整轮里唯一跑赢门槛的case，无bad case可记。

## statoil-iceberg-classifier-challenge — completed，0.35517 vs bronze 0.14552（越低越好）
```python
b1_mean = np.mean(band1, axis=(1, 2))   # 75x75双通道SAR图像被压成标量
xgb = XGBClassifier(n_estimators=300, max_depth=6, ...)
```
12版脚本从baseline到final_attempt_best全部走同一条路：把每张图压成约23个标量统计量喂给XGBoost/LightGBM，全程没试过CNN——环境里torch/tensorflow/keras都已装好，不是环境限制。压缩掉的正是区分冰山和船体的空间纹理结构，OOF log loss全程卡在0.34~0.39。另外最终提交的final_attempt_best.py（OOF 0.3608）比同批更优的baseline.py（OOF 0.3396）还差，选错了checkpoint。

## tgs-salt-identification-challenge — invalid_submission，"submission file does not exist"
只有3次工具调用（`ls -R`、`ls -R data/`、读`description.md`），随后模型陷入重复输出，thinking内容长达94968字符，末尾是逐个文件后缀名的死循环：
"Wait, I'll also check if there's any `.bmp` files. Actually, I'll just do it. Wait, I'll also check if there's any `.jpg` files..."
一直循环到打满maxTokens硬上限（output=32768，正好等于上限），从未写过一行代码，自然没有submission文件。这是模型生成本身的退化循环，和上下文窗口大小无关（Gemma有262144上下文，远没用满）。
