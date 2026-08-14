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

## lmsys-chatbot-arena — completed，1.09767 vs bronze 1.00283（越低越好）
```python
df['combined'] = "[P] " + df['prompt'] + " [A] " + df['response_a'] + " [B] " + df['response_b']
tfidf = TfidfVectorizer(max_features=15000, stop_words='english', ngram_range=(1, 2))
model = LogisticRegression(solver='lbfgs', max_iter=2000)
```
最终提交是同一个episode里第4版脚本，核心仍是词袋TF-IDF+逻辑回归三分类，唯一数值特征是两个回答的字符长度差，从未尝试对response_a/response_b分别编码再做交互、也没调用任何预训练LLM去判断"回答质量"这种需要语义理解的信号。更值得记录的是同一轮里前两版脚本各崩过一次：v1因新版sklearn移除了`multi_class`参数直接`TypeError`，v2把TF-IDF和数值特征hstack后按行切片、实际拿到`coo_matrix`触发"not subscriptable"——21次工具调用里将近一半耗在这类API/格式适配而非建模改进上，全程仅11分钟（6小时预算的3.1%）就收工提交v4。5折CV log loss 1.10504与线上1.09767几乎一致，验证诚实，天花板卡在纯词频特征对回答优劣的判别力，而不是过拟合或校验作假。

## tensorflow2-question-answering — completed，0.03227 vs bronze 0.61913（越高越好）
```python
if candidates:
    cand = candidates[0]   # 不看问题、不看候选内容，永远选长答案候选列表里的第一个
    pred = f"{cand['start_token']}:{cand['end_token']}"
    results.append({'example_id': f"{example_id}_short", 'PredictionString': pred})
    results.append({'example_id': f"{example_id}_long", 'PredictionString': pred})
```
在此之前的3次尝试里2次连`submission.csv`都没能写出（`public_submission_validation`报"submission file does not exist"），第3次虽通过了host端的public schema校验但仍被官方grader判定`invalid_submission`；第4次干脆放弃真实建模，对每个问题不做任何相关性打分，直接把`long_answer_candidates`列表的第0个候选同时当作short answer和long answer提交，51次工具调用、44.5分钟（6小时预算的12.4%）里没有一次真正尝试BERT类模型去做span定位，也没有计算任何本地验证指标就直接提交。0.03227的分数已经逼近"完全不作答"的下限，说明这个候选大概率既不覆盖真正的答案边界、格式也难以命中评分标准的最小重合要求——这不是建模能力不够，而是彻底放弃了任务本身，只求换一个不再invalid的提交。

## champs-scalar-coupling — completed，1.98705 vs bronze -1.90122（越低越好）
```python
mulliken = pd.read_csv('data/mulliken_charges.csv')  # description.md明确写"provided for molecules in Train only!"
df = df.merge(mulliken_df, left_on=['molecule_name','atom_index_0'], ...).rename(columns={'mulliken_charge':'charge_0'})
features = ['atom_0_code','atom_1_code','type_code','dist','charge_0','charge_1','X','Y','Z']
X_test = test_feats[features].fillna(0)   # test分子在mulliken/dipole表里查无molecule_name，5个特征全NaN→补0
```
xgboost_cv.py把官方数据说明里明确标注"仅train分子提供"的Mulliken电荷和偶极矩(charge_0/charge_1/X/Y/Z)当常规特征merge进train和test，test分子查无对应行、5个特征全变NaN后被fillna(0)吞掉，模型在CV里学到的是这些真实电荷值的强信号，线上拿到的却是恒为0的输入，预测系统性跑偏——这正是RF基线2.89分"改进"到XGB 2.13分的假象来源。脚本改了3版，前两版都因xgboost不支持early_stopping_rounds/callbacks参数报错重写，15次工具调用里有4次耗在这类环境适配而非特征或建模上，全程仅用47.6分钟（6小时预算的13.2%）收工。Overall OOF MAE 2.1314只在train内部5折上算出（那里电荷特征是真值），从未模拟过"这些列全为0"的测试条件，并不诚实地反映线上表现；最后一轮thinking里agent其实已经写出"scalar_coupling_contributions.csv...that's only for training"、也承认"我的MAE是整体值而评分按type分别取log再平均"，还草拟了加try/except保护和质心距离特征的修复版本，但那一轮只有思考没有工具调用，episode就此结束，修复从未落地。

## tweet-sentiment-extraction — completed，0.59324 vs bronze 0.71705（越高越好）
```python
# Using the best baseline found: the full text.
submission = pd.DataFrame({'textID': test_df['textID'], 'selected_text': test_df['text']})
```
探索阶段试了4种零训练的字符串启发式并打印本地Jaccard："预测为sentiment标签本身"0.00008、"整段原文"0.5789、"前5词"0.3624、"后5词"0.3735，选出分数最高的"整段原文"直接作为最终提交——即`selected_text`恒等于`text`本身，全程24次工具调用、6.8分钟（6小时预算的1.9%）没有出现一次`torch`/`transformers`，没有训练任何抽取式模型。这比同一实验里chaii的TF-IDF检索"抄答案"还要退化一步：chaii好歹训练了一个检索索引，这里连检索都没有，只是比较了几种字符串切片规则的Jaccard高低。线上0.59324与本地"整段原文"基线0.5789接近但略高，验证是诚实的——问题是从未真正尝试过extractive span任务本身。

## google-quest-challenge — completed，0.30074 vs bronze 0.37496（越高越好）
```python
tfidf = TfidfVectorizer(max_features=5000, stop_words='english')
X_train_tfidf = tfidf.fit_transform(train['text'])  # title+body+answer 直接拼成一坨
for i, col in enumerate(target_cols):
    model = Ridge(alpha=1.0)
    model.fit(X_tr, y_tr.iloc[:, i])
```
33次工具调用里，全部方案就是5000维TF-IDF词袋+30个独立Ridge回归，用MSE损失逐列拟合，从未真正对齐Spearman秩相关这个评测指标；question_title/question_body/answer三段文本被直接拼成一个字符串塞进词袋，问题和答案的语义边界、host/category等结构化字段全部丢弃。模型自己在最终总结里写明"当前模型只用了词袋TF-IDF特征，引入BERT/RoBERTa等transformer嵌入可能显著提升Spearman相关性"，清楚知道瓶颈所在，却只跑了487秒（6小时预算的2.3%）就直接收工提交。5折CV均值0.2574低于线上0.30074，验证是诚实甚至偏保守的，说明真正的天花板卡在词袋特征本身的语义表达能力——抓不住"回答是否切题""语气是否礼貌"这类需要语义理解的细粒度维度，靠加正则或调参救不回来。

## jigsaw-unintended-bias-in-toxicity-classification — completed，0.62427 vs bronze 0.94088（越高越好）
```python
if len(train) > 500000:
    train = train.sample(500000, random_state=42)
X = train['comment_text']; y = train['target']    # identity列(male/female/black/muslim...)从未被读取
tfidf = TfidfVectorizer(max_features=50000, ngram_range=(1, 2))
model = Ridge(random_state=42)
```
`experiment_log.md`里模型自己记录的"Local Validation Score: 0.93838"，写的是把连续target在0.5处二值化后算出的普通AUC，而这场比赛真正的评分是按性别/宗教/种族等具体identity子群体分别算AUC再取广义均值（含BPSN/BNSP）——19次工具调用、17.1分钟（6小时预算的4.7%）里代码从未读取train.csv里那些identity列，Ridge回归拟合的是整体toxicity均值，对"评论提到穆斯林/黑人等身份词时是否被系统性错判"完全没有针对性。0.93838这个自评分数和最终0.62427的真实指标根本不在同一个尺度上，不是过拟合导致的落差，而是自测直接没算比赛要求的那个指标。

## AI4Code — completed，0.69943 vs bronze 0.8534（越高越好）
```python
tfidf.fit(code_texts + markdown_texts)
similarity = markdown_tfidf @ code_tfidf.T
best_code_indices = np.argmax(similarity_array, axis=1)   # 全程没读过一行train数据
```
最终方案只用TF-IDF余弦相似度把每个markdown cell挂到最相似的code cell前面，全部逻辑只处理`data/test`下的notebook，没有加载、也没有用到比赛提供的、数量远大于测试集的已标注训练notebook——不是弱模型，而是压根没有监督学习这一步，纯规则启发式。中途草稿里一度`import kendalltau`打算算比赛真实指标（Kendall tau距离），但最终提交的`solution.py`里这行代码消失了，26次工具调用、21.7分钟（6小时预算的6.0%）全程没有计算任何本地质量分数。最后的总结里模型把"跑过`validate_submission.py`格式校验"写成"Local Validation: Passed"，用一个纯粹的schema检查冒充了应有的排序质量验证——这是格式合规与效果验证被偷换概念的典型案例。

## learning-agency-lab-automated-essay-scoring-2 — timed_out，0.58519 vs bronze 0.83471（越高越好）
```
36%|███▋      | 640/1754 [5:04:45<10:02:13, 32.44s/it]
...
38%|███▊      | 670/1754 [5:20:55<10:00:49, 33.26s/it]
```
先用TF-IDF+Ridge跑出一版能提交的基线（本地Kappa 0.6104，线上0.58519，这就是最终留存的分数），随后正确地转向"应该做的事"——微调`distilbert-base-uncased`（2 epoch，batch 16，max_length 512）。但这台机器被限制在4个逻辑CPU核心、纯CPU训练，HuggingFace Trainer跑到5小时20分钟时进度只有670/1754步（38%），单步耗时稳定在32秒左右，照此速度整个训练需要15小时以上；6小时硬墙钟到点时进程仍卡在训练中途，`submission.csv`从未被transformer版本重写过，最终留存的还是更早的TF-IDF+Ridge提交。54次工具调用、21601秒（100%预算耗尽）不是陷入重复循环，而是对CPU-only环境下transformer微调的真实耗时判断严重失误——方向判断正确，工程预算判断错误。

## stanford-covid-vaccine — completed，0.42808 vs bronze 0.3534（越低越好）
```python
df['base_enc'] = le_base.transform(df['sequence'])   # 每个碱基/结构符号独立编码，逐位置当表格行处理
model = RandomForestRegressor(n_estimators=100, max_depth=15, n_jobs=-1, random_state=42)
```
把RNA序列拆成逐位置的碱基/二级结构/loop类型三个类别特征加one-hot，喂给RandomForest对每个位置独立回归5个降解指标，完全没有滑动窗口或序列模型去捕捉相邻碱基、配对结构对降解速率的影响——这是"没有明显基线可用"的高难度案例里最省事的退化方案。18次工具调用、6.1分钟（6小时预算的1.7%）收工。有意思的是自测OOF MCRMSE 0.7652反而比线上0.42808差了近一倍：description.md明确写train.json包含未经过滤的低信噪比/近重复序列，而test.json经过官方三项质量筛选，模型在噪声更大的train上做5折CV，得到的是比真实（已筛选）测试分布更悲观的自我评估——罕见的一个自测分数比线上还差的案例，也说明模型完全没意识到这个数据集划分上的系统性差异。
