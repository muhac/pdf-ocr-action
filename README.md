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
    runs-on: macos-15
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

**Languages.** Common codes: `eng`, `chi_sim`, `chi_tra`, `jpn`, `kor`, `fra`, `deu`, `spa`, `ita`, `por`, `rus`. The [full list](https://github.com/mkyt/OCRmyPDF-AppleOCR#supported-languages) has about 30. Only one language can be given per run, but Latin text inside a Chinese, Japanese or Korean page is still recognized.

### Run it as your own OCR service

Your PDFs live in a private repository that only you can see. Your copy of this repository does the OCR and never stores them.

```
you ── add PDF ──▶ private repository: inbox/
                        │ asks the service to run
                        ▼
                 your copy of pdf-ocr-action (macOS runner)
                        │
                        ▼
                   private repository: done/   (failed/ if a file cannot be processed)
```

Setup, about ten minutes:

1. **Service repository.** Fork this repository, then open the fork's **Actions** tab and enable workflows.
2. **Documents repository.** Create a new *private* repository and copy the contents of [`template/`](template) into it (`.github/workflows/request-ocr.yml` and `inbox/.gitkeep`).
3. **Let the service reach your documents.** Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) limited to the documents repository with **Contents: Read and write**. In the service repository, under *Settings → Secrets and variables → Actions*, add two secrets:
   - `STORAGE_TOKEN`: the token
   - `STORAGE_REPO`: `your-name/your-documents`
4. **Let your documents call the service.** Create a second fine-grained token limited to the service repository with **Actions: Read and write**. In the documents repository add:
   - secret `SERVICE_TOKEN`: the token
   - variable `SERVICE_REPO`: `your-name/pdf-ocr-action`
   - variable `OCR_LANGUAGE` (optional): for example `chi_sim`

Then add a PDF to `inbox/`, by `git push` or by uploading on github.com. A few minutes later it appears in `done/` under the same name and is removed from `inbox/`. Files that cannot be processed are moved to `failed/`.

Step 4 is optional: without it, start the **OCR** workflow by hand from the service repository's Actions tab.

### Privacy

- PDFs are stored only in your private repository. They are processed on a GitHub-hosted runner that is discarded after the job. No third-party OCR service is involved.
- The service repository is public and so are its logs. The service only logs counts, such as `[1/3] done`, never file names or the name of your documents repository. Keep both in secrets as described above.
- Anyone who obtains `STORAGE_TOKEN` can read your documents. Limit it to the one repository and give it an expiry date.
- GitHub Actions use is subject to [GitHub's terms](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#actions). macOS runners are free for public repositories and billed by the minute for private ones. The service setup is meant for light personal use.

### Limits

- macOS runners only (Apple's OCR is not available elsewhere).
- One language per run.
- The service reads PDFs directly inside `inbox/`, not in subfolders, and GitHub rejects files larger than 100 MB.

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
    runs-on: macos-15
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

**语言。** 常用代码：`chi_sim`（简体中文）、`chi_tra`（繁体中文）、`eng`、`jpn`、`kor`、`fra`、`deu`、`spa`、`rus`。[完整列表](https://github.com/mkyt/OCRmyPDF-AppleOCR#supported-languages)约 30 种。每次只能指定一种语言，不过中日韩文页面里夹杂的英文和数字仍然能识别。

### 搭建自己的 OCR 服务

PDF 存在只有你能看到的私有仓库里，你自己的这份 pdf-ocr-action 负责识别，不保存任何文件。

```
你 ── 放入 PDF ──▶ 私有仓库：inbox/
                       │ 通知服务开始处理
                       ▼
                你自己的 pdf-ocr-action（macOS runner）
                       │
                       ▼
                  私有仓库：done/   （处理不了的文件进 failed/）
```

配置大约十分钟：

1. **服务仓库。** Fork 本仓库，然后在 fork 的 **Actions** 页启用 workflow。
2. **文档仓库。** 新建一个**私有**仓库，把 [`template/`](template) 里的内容复制进去（`.github/workflows/request-ocr.yml` 和 `inbox/.gitkeep`）。
3. **让服务能访问你的文档。** 创建一个 [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)，只授权文档仓库，权限选 **Contents: Read and write**。在服务仓库的 *Settings → Secrets and variables → Actions* 里添加两个 secret：
   - `STORAGE_TOKEN`：这个 token
   - `STORAGE_REPO`：`你的用户名/你的文档仓库`
4. **让文档仓库能调用服务。** 再创建一个 fine-grained token，只授权服务仓库，权限选 **Actions: Read and write**。在文档仓库里添加：
   - secret `SERVICE_TOKEN`：这个 token
   - variable `SERVICE_REPO`：`你的用户名/pdf-ocr-action`
   - variable `OCR_LANGUAGE`（可选）：例如 `chi_sim`

之后把 PDF 放进 `inbox/` 即可，用 `git push` 或在 github.com 网页上传都行。几分钟后，同名文件会出现在 `done/`，`inbox/` 里的原件被移除。处理不了的文件会被移到 `failed/`。

第 4 步可以不做：这样就需要到服务仓库的 Actions 页手动运行 **OCR** workflow。

### 隐私

- PDF 只存放在你的私有仓库。处理在 GitHub 托管的 runner 上进行，任务结束后 runner 即销毁。不经过任何第三方 OCR 服务。
- 服务仓库是公开的，它的日志也是公开的。服务只记录数量（如 `[1/3] done`），不记录文件名，也不记录文档仓库的名字。请按上面的说明把这两项放在 secret 里。
- 拿到 `STORAGE_TOKEN` 的人可以读取你的文档。请只授权那一个仓库，并设置过期时间。
- 使用 GitHub Actions 须遵守 [GitHub 的条款](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features#actions)。macOS runner 对公开仓库免费，对私有仓库按分钟计费。服务这种用法适合个人少量使用。

### 限制

- 只能在 macOS runner 上运行（Apple 的文字识别在其他系统上不可用）。
- 每次只能指定一种语言。
- 服务只读取 `inbox/` 下的 PDF，不读子文件夹；GitHub 不接受超过 100 MB 的文件。

### 本地运行

在装有 [uv](https://docs.astral.sh/uv/) 并执行过 `brew install tesseract` 的 Mac 上：

```sh
OCR_LANGUAGE=chi_sim scripts/ocr.sh scan.pdf searchable.pdf
tests/run.sh   # 端到端测试
```

### 致谢

基于 [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) 和 [OCRmyPDF-AppleOCR](https://github.com/mkyt/OCRmyPDF-AppleOCR)。以 [MIT](LICENSE) 许可证发布。
