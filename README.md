# PDF OCR Action

[English](#english) | [中文](#中文)

## English

Turn scanned PDFs into searchable PDFs — text you can select, copy and search — with the OCR engine built into macOS, running on GitHub's macOS runners. It is fast, runs entirely on the runner, and is especially good at Chinese, Japanese and Korean.

There are two ways to use it:

- [In a workflow](#use-it-in-a-workflow): one step that converts a file or a folder.
- [As your own OCR service](#run-it-as-your-own-ocr-service): drop a PDF into a private repository, get the searchable version back a few minutes later.

### Use it in a workflow

```yaml
jobs:
  ocr:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7
      - uses: muhac/pdf-ocr-action@v1
        with:
          input: scans
          output: searchable
          language: eng
      - uses: actions/upload-artifact@v7
        with:
          name: searchable-pdfs
          path: searchable
```

| Input | Default | Meaning |
| --- | --- | --- |
| `input` | required | A PDF file, or a folder of PDF files |
| `output` | required | Output file when `input` is a file, output folder when it is a folder |
| `language` | `eng` | One language code (see below) |
| `mode` | `skip` | `skip` leaves pages that already have text alone; `force` runs OCR on every page |
| `recognition` | `livetext` | `livetext`, `accurate` or `fast` |
| `quiet` | `false` | `true` keeps file names and OCR output out of the log |
| `args` | | Extra arguments passed to `ocrmypdf` |

When `input` is a folder, a file that cannot be processed does not stop the others; the step fails at the end and the good results are still written.

**Languages.** Common codes: `eng`, `chi_sim`, `chi_tra`, `jpn`, `kor`, `fra`, `deu`, `spa`, `ita`, `por`, `rus`. The [full list](https://github.com/mkyt/OCRmyPDF-AppleOCR#supported-languages) has about 30. Each PDF is read in one language, but Latin text inside a Chinese, Japanese or Korean page is still recognized.

**Several languages at once.** When `input` is a folder, PDFs in a subfolder named after a language code are read in that language, and the output keeps the subfolder: `scans/chi_tra/a.pdf` becomes `searchable/chi_tra/a.pdf`. PDFs directly in the folder use `language`. Other subfolders are ignored.

### Run it as your own OCR service

Your PDFs live in a private repository that only you can see. Your copy of this repository does the OCR and never stores them.

```
you ── add PDF ──▶ private repository: inbox/
                        │
                        ▼
                 your copy of pdf-ocr-action (macOS runner)
                        │
                        ▼
                   private repository: done/   (failed/ if a file cannot be processed)
```

#### Set up

1. **Service repository.** Fork this repository, then open the fork's **Actions** tab and enable workflows.
2. **Documents repository.** Pick any private repository of yours, new or existing. Nothing has to be installed in it.
3. **Connect them.** Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) limited to the documents repository with **Contents: Read and write**. In the service repository, under *Settings → Secrets and variables → Actions*, add these secrets:

| Secret | Value |
| --- | --- |
| `STORAGE_TOKEN` | The token |
| `STORAGE_REPO` | `your-name/your-documents` |
| `STORAGE_INBOX` | Optional. Folder PDFs are taken from (default `inbox`) |
| `STORAGE_DONE` | Optional. Folder the searchable results are put in (default `done`) |
| `STORAGE_FAILED` | Optional. Folder for PDFs that cannot be processed (default `failed`) |

Folders may be nested, for example `scans/todo`. The service downloads only these three folders, so the rest of the documents repository can hold anything else, such as an organized library, without slowing it down. To change the language from the default `eng`, add a repository *variable* `OCR_LANGUAGE`, for example `chi_sim`.

#### Use

Add PDFs to the inbox folder, by `git push` or by uploading on github.com. Then start the **OCR** workflow from the service repository's Actions tab, or from a terminal:

```sh
gh workflow run ocr.yml --repo your-name/pdf-ocr-action
```

A few minutes later each PDF appears in the done folder under the same name and is removed from the inbox. Files that cannot be processed are moved to the failed folder.

PDFs directly in the inbox are read in the default language. For another language, put them in a subfolder named after its code, such as `inbox/chi_sim/` or `inbox/chi_tra/`; the result appears in the same subfolder of the done folder.

#### Start it automatically

To have the service start by itself whenever a PDF arrives, add this workflow to the documents repository as `.github/workflows/ocr.yml`:

```yaml
on:
  push:
    branches: [main]
    paths: ["inbox/**"]
  release:
    types: [published]

jobs:
  trigger:
    runs-on: ubuntu-latest
    steps:
      - uses: muhac/pdf-ocr-action/trigger@v1
        with:
          service: your-name/pdf-ocr-action
          token: ${{ secrets.SERVICE_TOKEN }}
```

`SERVICE_TOKEN` is a second fine-grained token, limited to the service repository with **Actions: Read and write**, saved as a secret in the documents repository. The trigger also accepts `language` and `mode`. With `branch`, the service works on that branch of the documents repository instead of its default branch: results are committed there, so a pull request can be squash-merged to keep the originals out of the default branch's history. The branch name is masked in the service's public log, but choose names that say nothing about the documents anyway. The `release` part is only needed for large files, described next; `branches` keeps the tag of a new release from starting a second run.

#### Files larger than 100 MB

Git does not accept files over 100 MB. Send those through a release of the documents repository instead, which allows up to 2 GB per file:

1. Create a release in the documents repository, attach the PDF and publish it.
2. Run the service, unless it starts automatically.
3. The service attaches two files to the same release: `book.ocr.pdf`, the searchable result, and `book.ocr.log`, whose first line is `done` or `failed`.

- A PDF is processed when there is no `.ocr.log` next to it. Delete the log to have the PDF processed again; add one yourself to have a PDF left alone.
- To choose the language, put its code alone on the first line of the release description, for example `chi_tra`.
- GitHub drops non-Latin characters from attachment names (`测试.pdf` is stored as `default.pdf`), so put the real name in the release title.
- Draft releases are ignored.

### Privacy

- PDFs are stored only in your private repository. They are processed on a GitHub-hosted runner that is discarded after the job. No third-party OCR service is involved.
- The service repository is public and so are its logs. The service only logs counts, such as `[1/3] done`, never file names, folder names, release names or the name of your documents repository. That is why those settings are secrets.
- Anyone who obtains `STORAGE_TOKEN` can read your documents. Limit it to the one repository and give it an expiry date.
- GitHub Actions use is subject to [GitHub's terms](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#actions). macOS runners are free for public repositories and billed by the minute for private ones. The service setup is meant for light personal use.

### Limits

- macOS runners only (Apple's OCR is not available elsewhere). Tested on `macos-15` and `macos-26`; `macos-14` is not supported.
- One language per PDF.
- The service reads PDFs directly inside the inbox folder and its language subfolders, nothing deeper. Files larger than 100 MB have to go through a release.

### Run it locally

On a Mac with [uv](https://docs.astral.sh/uv/) and `brew install tesseract`:

```sh
OCR_LANGUAGE=chi_sim scripts/ocr.sh scan.pdf searchable.pdf
tests/run.sh   # end-to-end tests
```

### Credits

Built on [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) and [OCRmyPDF-AppleOCR](https://github.com/mkyt/OCRmyPDF-AppleOCR). Licensed under [MIT](LICENSE).

---

## 中文

把扫描版 PDF 变成可搜索的 PDF——文字可以选中、复制、搜索。使用 macOS 自带的文字识别引擎，在 GitHub 的 macOS runner 上运行。速度快，全程在 runner 本机完成，中文、日文、韩文的识别效果尤其好。

有两种用法：

- [在 workflow 里调用](#在-workflow-里调用)：一个步骤，转换一个文件或一个文件夹。
- [搭建自己的 OCR 服务](#搭建自己的-ocr-服务)：把 PDF 放进私有仓库，几分钟后拿回可搜索的版本。

### 在 workflow 里调用

```yaml
jobs:
  ocr:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7
      - uses: muhac/pdf-ocr-action@v1
        with:
          input: scans
          output: searchable
          language: chi_sim
      - uses: actions/upload-artifact@v7
        with:
          name: searchable-pdfs
          path: searchable
```

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `input` | 必填 | 一个 PDF 文件，或一个放 PDF 的文件夹 |
| `output` | 必填 | `input` 是文件时为输出文件，是文件夹时为输出文件夹 |
| `language` | `eng` | 一个语言代码（见下） |
| `mode` | `skip` | `skip` 跳过已有文字的页面；`force` 对每一页都重新识别 |
| `recognition` | `livetext` | `livetext`、`accurate` 或 `fast` |
| `quiet` | `false` | 设为 `true` 后，日志里不出现文件名和识别过程的输出 |
| `args` | | 传给 `ocrmypdf` 的额外参数 |

`input` 是文件夹时，某个文件处理失败不会影响其他文件；该步骤最后会报失败，但成功的结果照常输出。

**语言。** 常用代码：`chi_sim`（简体中文）、`chi_tra`（繁体中文）、`eng`、`jpn`、`kor`、`fra`、`deu`、`spa`、`rus`。[完整列表](https://github.com/mkyt/OCRmyPDF-AppleOCR#supported-languages)约 30 种。每份 PDF 按一种语言识别，不过中日韩文页面里夹杂的英文和数字仍然能识别。

**同时处理多种语言。** `input` 是文件夹时，放在以语言代码命名的子文件夹里的 PDF 会按该语言识别，输出保持同样的子文件夹：`scans/chi_tra/a.pdf` 对应 `searchable/chi_tra/a.pdf`。直接放在文件夹里的 PDF 使用 `language`。其他子文件夹会被忽略。

### 搭建自己的 OCR 服务

PDF 存在只有你能看到的私有仓库里，你自己的这份 pdf-ocr-action 负责识别，不保存任何文件。

```
你 ── 放入 PDF ──▶ 私有仓库：inbox/
                       │
                       ▼
                你自己的 pdf-ocr-action（macOS runner）
                       │
                       ▼
                  私有仓库：done/   （处理不了的文件进 failed/）
```

#### 配置

1. **服务仓库。** Fork 本仓库，然后在 fork 的 **Actions** 页启用 workflow。
2. **文档仓库。** 任选一个你自己的私有仓库，新建或现有的都行，里面不需要安装任何东西。
3. **把两者连起来。** 创建一个 [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)，只授权文档仓库，权限选 **Contents: Read and write**。在服务仓库的 *Settings → Secrets and variables → Actions* 里添加以下 secret：

| Secret | 值 |
| --- | --- |
| `STORAGE_TOKEN` | 上面创建的 token |
| `STORAGE_REPO` | `你的用户名/你的文档仓库` |
| `STORAGE_INBOX` | 可选。从哪个文件夹取 PDF（默认 `inbox`） |
| `STORAGE_DONE` | 可选。识别结果放到哪个文件夹（默认 `done`） |
| `STORAGE_FAILED` | 可选。处理不了的 PDF 放到哪个文件夹（默认 `failed`） |

文件夹可以是多级路径，例如 `scans/todo`。服务只下载这三个文件夹，文档仓库里的其他内容（比如整理好的资料库）不会被下载，也不会拖慢它。默认语言是 `eng`，要改的话添加一个仓库 *variable* `OCR_LANGUAGE`，例如 `chi_sim`。

#### 使用

把 PDF 放进收件文件夹，用 `git push` 或在 github.com 网页上传都行。然后到服务仓库的 Actions 页运行 **OCR** workflow，或者在终端执行：

```sh
gh workflow run ocr.yml --repo 你的用户名/pdf-ocr-action
```

几分钟后，同名文件会出现在结果文件夹里，收件文件夹里的原件被移除。处理不了的文件会被移到失败文件夹。

直接放在收件文件夹里的 PDF 按默认语言识别。要用其他语言，就放进以语言代码命名的子文件夹，例如 `inbox/chi_sim/` 或 `inbox/chi_tra/`；结果会出现在结果文件夹的同名子文件夹里。

#### 自动触发

想让服务在 PDF 到达时自动开始，就在文档仓库里添加这个 workflow，保存为 `.github/workflows/ocr.yml`：

```yaml
on:
  push:
    branches: [main]
    paths: ["inbox/**"]
  release:
    types: [published]

jobs:
  trigger:
    runs-on: ubuntu-latest
    steps:
      - uses: muhac/pdf-ocr-action/trigger@v1
        with:
          service: 你的用户名/pdf-ocr-action
          token: ${{ secrets.SERVICE_TOKEN }}
```

`SERVICE_TOKEN` 是第二个 fine-grained token，只授权服务仓库，权限选 **Actions: Read and write**，作为 secret 保存在文档仓库里。trigger 还接受 `language` 和 `mode` 两个参数。加上 `branch` 参数，服务会在文档仓库的那个分支上工作而不是默认分支：结果提交到该分支，之后用 squash 合并 PR，原件就不会进入默认分支的历史。分支名在服务的公开日志里会被遮盖，但仍建议分支名不要透露文档内容。`release` 那部分只在处理大文件时需要，见下一节；`branches` 是为了避免新 Release 的标签再触发一次运行。

#### 超过 100 MB 的文件

Git 不接受超过 100 MB 的文件。这类文件改用文档仓库的 Release 传递，单个文件最大 2 GB：

1. 在文档仓库新建一个 Release，把 PDF 作为附件上传并发布。
2. 运行服务；配置了自动触发的话不用手动运行。
3. 服务会往同一个 Release 里添加两个文件：`book.ocr.pdf` 是可搜索的结果，`book.ocr.log` 的第一行是 `done` 或 `failed`。

- 一个 PDF 旁边没有对应的 `.ocr.log` 时才会被处理。删掉日志就会重新处理；自己放一个日志进去，这个 PDF 就不会被处理。
- 要指定语言，把语言代码单独写在 Release 说明的第一行，例如 `chi_tra`。
- GitHub 会去掉附件文件名里的非拉丁字符（`测试.pdf` 会被存成 `default.pdf`），所以真正的名字请写在 Release 的标题里。
- 草稿状态的 Release 不会被处理。

### 隐私

- PDF 只存放在你的私有仓库。处理在 GitHub 托管的 runner 上进行，任务结束后 runner 即销毁。不经过任何第三方 OCR 服务。
- 服务仓库是公开的，它的日志也是公开的。服务只记录数量（如 `[1/3] done`），不记录文件名、文件夹名、Release 名，也不记录文档仓库的名字。这些配置之所以放在 secret 里，就是这个原因。
- 拿到 `STORAGE_TOKEN` 的人可以读取你的文档。请只授权那一个仓库，并设置过期时间。
- 使用 GitHub Actions 须遵守 [GitHub 的条款](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#actions)。macOS runner 对公开仓库免费，对私有仓库按分钟计费。服务这种用法适合个人少量使用。

### 限制

- 只能在 macOS runner 上运行（Apple 的文字识别在其他系统上不可用）。已在 `macos-15` 和 `macos-26` 上测试通过；不支持 `macos-14`。
- 每份 PDF 只能按一种语言识别。
- 服务只读取收件文件夹及其语言子文件夹里的 PDF，不读更深的层级。超过 100 MB 的文件需要通过 Release 传递。

### 本地运行

在装有 [uv](https://docs.astral.sh/uv/) 并执行过 `brew install tesseract` 的 Mac 上：

```sh
OCR_LANGUAGE=chi_sim scripts/ocr.sh scan.pdf searchable.pdf
tests/run.sh   # 端到端测试
```

### 致谢

基于 [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) 和 [OCRmyPDF-AppleOCR](https://github.com/mkyt/OCRmyPDF-AppleOCR)。以 [MIT](LICENSE) 许可证发布。
