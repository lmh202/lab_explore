#!/usr/bin/env python
# coding: utf-8

# # EDA which makes sense (TPSMAY22)
# 
# After a general overview of the data, this EDA shows in particular:
# - The distributions of the features and the information they give about the target
# - [How to deal with the string feature `f_27`](https://www.kaggle.com/code/ambrosm/tpsmay22-eda-which-makes-sense#The-string-feature) (→ feature engineering)
# - [How to exploit the three most important feature interactions](https://www.kaggle.com/code/ambrosm/tpsmay22-eda-which-makes-sense#Top-three-feature-interactions) (→ feature engineering)

# In[ ]:


import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator
from matplotlib.colors import ListedColormap
import seaborn as sns
from cycler import cycler
from IPython.display import display
import datetime

from sklearn.decomposition import PCA
from sklearn.preprocessing import StandardScaler
from sklearn.feature_selection import mutual_info_classif

plt.rcParams['axes.facecolor'] = '#0057b8' # blue
plt.rcParams['axes.prop_cycle'] = cycler(color=['#ffd700'] +
                                         plt.rcParams['axes.prop_cycle'].by_key()['color'][1:])


# Let's start by reading the data and looking at the first few rows:

# In[ ]:


train = pd.read_csv('../input/tabular-playground-series-may-2022/train.csv')
test = pd.read_csv('../input/tabular-playground-series-may-2022/test.csv')

print()
print('Train')
display(train.head(3))

print()
print('Test')
display(test.head(3))

print('Dataframe shapes:', train.shape, test.shape)
print()


# We have 900000 training samples and 700000 test samples. Both dataframes have an id column and 31 features. There are 16 float features, 14 int features and one string feature. There are no missing values:

# In[ ]:


train.info()


# # The target
# 
# The target is binary. With 51 % zeros and 49 % ones, it is almost balanced:

# In[ ]:


(train.target.value_counts() / len(train)).round(2)


# # The 16 float features
# 
# The histograms of the 16 float features show that all these features are normally distributed with the center at zero. `f_00` through `f_06` have a standard deviation of 1; `f_19` through `f_26` have a standard deviation between 2.3 and 2.5, and `f_28` has a standard deviation of almost 240. Training and test data have the same distribution. There seem to be no outliers:

# In[ ]:


float_features = [f for f in train.columns if train[f].dtype == 'float64']

# Training histograms
fig, axs = plt.subplots(4, 4, figsize=(16, 16))
for f, ax in zip(float_features, axs.ravel()):
    ax.hist(train[f], density=True, bins=100)
    ax.set_title(f'Train {f}, std={train[f].std():.1f}')
plt.suptitle('Histograms of the float features', y=0.93, fontsize=20)
plt.show()

# Test histograms
# fig, axs = plt.subplots(4, 4, figsize=(16, 16))
# for f, ax in zip(float_features, axs.ravel()):
#     ax.hist(test[f], density=True, bins=100)
#     ax.set_title(f'Test {f}, std={test[f].std():.1f}')
# plt.show()


# The correlation matrix shows:
# 1. `f_00` through `f_06` are correlated with `f_28`, but not with each other. 
# 2. `f_19` through `f_26` are all slightly correlated with each other.
# 3. No feature is strongly correlated with the target.

# In[ ]:


# Correlation matrix of the float features
plt.figure(figsize=(12, 12))
sns.heatmap(train[float_features + ['target']].corr(), center=0, annot=True, fmt='.2f')
plt.show()


# The correlation matrix shows only linear dependences. If we plot a rolling mean of the target probability for every feature, we'll see nonlinear dependences as well. A horizontal line means that the target does not depend on the feature (e.g., `f_03`, `f_04`, `f_06`), a line with low minimum and high maximum shows a high mutual information between feature and target (e.g., `f_19`, `f_21`, `f_28`). 

# In[ ]:


# Plot dependence between every feature and the target
def plot_mutual_info_diagram(df, features, ncols=4, by_quantile=True, mutual_info=True,
                             title='How the target probability depends on single features'):
    def H(p):
        """Entropy of a binary random variable in nat"""
        return -np.log(p) * p - np.log(1-p) * (1-p)

    nrows = (len(features) + ncols - 1) // ncols
    fig, axs = plt.subplots(nrows, ncols, figsize=(16, nrows*4), sharey=True)
    for f, ax in zip(features, axs.ravel()):
        temp = pd.DataFrame({f: df[f].values,
                             'state': df.target.values})
        temp = temp.sort_values(f)
        temp.reset_index(inplace=True)
        rolling_mean = temp.state.rolling(15000, center=True, min_periods=1).mean()
        if by_quantile:
            ax.scatter(temp.index, rolling_mean, s=2)
        else:
            ax.scatter(temp[f], rolling_mean, s=2)
        if mutual_info and by_quantile:
            ax.set_xlabel(f'{f} mi={H(temp.state.mean()) - H(rolling_mean[~rolling_mean.isna()].values).mean():.5f}')
        else:
            ax.set_xlabel(f'{f}')
    plt.suptitle(title, y=0.90, fontsize=20)
    plt.show()

plot_mutual_info_diagram(train, float_features,
                         title='How the target probability depends on the float features')


# **Insight:**
# - There are many nonlinear (and some nonmonotonic) relationships. Linear classifiers won't win this competition.

# # The integer features
# 
# Looking at the histograms of the integer features, we see that the first twelve features all have values between 0 and 16. The last two features are special: `f_29` is binary and `f_30` is ternary.

# In[ ]:


int_features = [f for f in test.columns if test[f].dtype == 'int64' and f != 'id']

# Training histograms
#fig, axs = plt.subplots(4, 4, figsize=(16, 16))
figure = plt.figure(figsize=(16, 16))
# for f, ax in zip(int_features, axs.ravel()):
for i, f in enumerate(int_features):
    plt.subplot(4, 4, i+1)
    ax = plt.gca()
    vc = train[f].value_counts()
    ax.bar(vc.index, vc)
    #ax.hist(train[f], density=False, bins=(train[f].max()-train[f].min()+1))
    ax.set_xlabel(f'Train {f}')
    ax.xaxis.set_major_locator(MaxNLocator(integer=True)) # only integer labels
plt.suptitle('Histograms of the integer features', y=1.0, fontsize=20)
figure.tight_layout(h_pad=1.0)
plt.show()

# Test histograms
# fig, axs = plt.subplots(4, 4, figsize=(16, 16))
# for f, ax in zip(int_features, axs.ravel()):
#     ax.hist(test[f], density=True, bins=100)
#     ax.set_title(f'Test {f}, std={test[f].std():.1f}')
# plt.show()


# In[ ]:


plot_mutual_info_diagram(train, int_features,
                         title='How the target probability depends on the int features')


# # The string feature `f_27`
# 
# `f_27` is a string feature which cannot be used as a feature as-is. Let's find out how to engineer something useful from it!
# 
# We first verify that the string always has length 10:

# In[ ]:


train.f_27.str.len().min(), train.f_27.str.len().max(), test.f_27.str.len().min(), test.f_27.str.len().max()


# The 900000 train samples contain 741354 different values, i.e. most of the strings are different. The most frequent string, `'BBBBBBCJBC'` occurs only 12 times:

# In[ ]:


train.f_27.value_counts()


# It is important to understand whether the `f_27` strings in test are the same as in training. Unfortunately, test contains 1181880 - 741354 = 440526 strings which do not occur in training. 
# 
# **Insight:** We must not use this string as a categorical feature in a classifier. Otherwise, the model learns to rely on strings which never occur in the test data.

# In[ ]:


pd.concat([train, test]).f_27.value_counts()


# In the next step, we look at the distributions of the letters at every one of the ten positions in the string. We see that positions 0, 2 and 5 are binary; the other positions have more values. Every position gives some information about the target (the target means depend on the feature value).

# In[ ]:


for i in range(10):
    print(f'Position {i}')
    tg = train.groupby(train.f_27.str.get(i))
    temp = pd.DataFrame({'size': tg.size(), 'probability': tg.target.mean().round(2)})
    print(temp)
    print()


# We can as well count the unique characters in the string and use this count as a feature (idea from @cabaxiom's [[TPS-MAY-22] EDA & LGBM Model](https://www.kaggle.com/code/cabaxiom/tps-may-22-eda-lgbm-model)). The table clearly shows that the target probability depends on the unique character count:

# In[ ]:


unique_characters = train.f_27.apply(lambda s: len(set(s))).rename('unique_characters')
tg = train.groupby(unique_characters)
temp = pd.DataFrame({'size': tg.size(), 'probability': tg.target.mean().round(2)})
print(temp)


# **Insight:**
# - The `f_27` strings must be split into ten individual features.
# - The count of unique characters in `f_27` is an important feature as well.
# 
# You can use the following lines of code to split the strings into ten numerical features:
# 

# In[ ]:


# From https://www.kaggle.com/ambrosm/tpsmay22-eda-which-makes-sense
for df in [train, test]:
    for i in range(10):
        df[f'ch{i}'] = df.f_27.str.get(i).apply(ord) - ord('A')
    df["unique_characters"] = df.f_27.apply(lambda s: len(set(s)))


# In[ ]:


plot_mutual_info_diagram(train, 
                         [f for f in train.columns if f.startswith('ch')] + ['unique_characters'],
                         title='How the target probability depends on the character features')


# # Top three feature interactions
# 
# In the topic [Interaction vs Correlation](https://www.kaggle.com/competitions/tabular-playground-series-may-2022/discussion/323766), @wti200 has demonstrated that certain 2d projections of the feature space are partitioned into three regions with differing target probabilities. From these diagrams, we can derive the feature interactions. Three projections are particularly useful:
# - the projection to f_02 and f_21
# - the projection to f_05 and f_22
# - the projection to f_00+f_01 and f_26

# In[ ]:


plt.rcParams['axes.facecolor'] = 'k'
plt.figure(figsize=(11, 5))
cmap = ListedColormap(["#ffd700", "#0057b8"])
# target == 0 → yellow; target == 1 → blue

ax = plt.subplot(1, 3, 1)
ax.scatter(train['f_02'], train['f_21'], s=1,
           c=train.target, cmap=cmap)
ax.set_xlabel('f_02')
ax.set_ylabel('f_21')
ax.set_aspect('equal')
ax0 = ax

ax = plt.subplot(1, 3, 2, sharex=ax0, sharey=ax0)
ax.scatter(train['f_05'], train['f_22'], s=1,
           c=train.target, cmap=cmap)
ax.set_xlabel('f_05')
ax.set_ylabel('f_22')
ax.set_aspect('equal')

ax = plt.subplot(1, 3, 3, sharex=ax0, sharey=ax0)
ax.scatter(train['f_00'] + train['f_01'], train['f_26'], s=1,
           c=train.target, cmap=cmap)
ax.set_xlabel('f_00 + f_01')
ax.set_ylabel('f_26')
ax.set_aspect('equal')

plt.tight_layout(w_pad=1.0)
plt.savefig('three-projections.png')
plt.show()
plt.rcParams['axes.facecolor'] = '#0057b8' # blue


# We now can either hope that our classifier finds these borders by itself, or we can help the classifier.
# 
# And how can we help a classifier? For every projection, we create a ternary categorical feature that indicates to which region a sample belongs:
# - Top right region (high probability of target == 1) → +1
# - Middle region (medium probability of target == 1) → 0
# - Bottom left region (low probability of target == 1) → -1
# 
# You can use the following lines of code to add the three features to the dataframes:

# In[ ]:


for df in [train, test]:
    df['i_02_21'] = (df.f_21 + df.f_02 > 5.2).astype(int) - (df.f_21 + df.f_02 < -5.3).astype(int)
    df['i_05_22'] = (df.f_22 + df.f_05 > 5.1).astype(int) - (df.f_22 + df.f_05 < -5.4).astype(int)
    i_00_01_26 = df.f_00 + df.f_01 + df.f_26
    df['i_00_01_26'] = (i_00_01_26 > 5.0).astype(int) - (i_00_01_26 < -5.0).astype(int)


# # What next?
# 
# If you like gradient-boosted decision trees, you might have a look at the [Gradient Boosting Quickstart](https://www.kaggle.com/ambrosm/tpsmay22-gradient-boosting-quickstart). Or if you prefer neural networks, have a look at the [Advanced Keras Model](https://www.kaggle.com/code/ambrosm/tpsmay22-advanced-keras).
# 
