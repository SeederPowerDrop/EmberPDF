# EmberPDF 0.9.0 Developer Preview

[한국어](#한국어) · [English](#english) · [Français](#français) · [Русский](#русский) · [简体中文](#简体中文)

## 한국어

### 프로젝트의 목적

EmberPDF는 여러 PDF를 읽고 비교하며 공부하거나 편집할 수 있는 macOS 앱입니다. 학생·연구자와 문서를 자주 다루는 사용자가 교재의 문장을 찾고, 필기하고, 여러 자료에서 필요한 페이지를 모으는 일을 한 작업 공간에서 할 수 있도록 만들었습니다. 기본 읽기·검색·편집·OCR은 Mac에서 동작합니다. 소스는 [MPL-2.0](../LICENSE)으로 공개합니다.

EmberPDF는 HwattakPDF의 새 이름입니다. 초기 소스와 릴리스 이력은 기존 GitHub 저장소에서 볼 수 있습니다. [HwattakPDF](https://github.com/SeederPowerDrop/HwattakPDF)

### 개발 과정

SwiftUI와 AppKit으로 작업 공간을 만들고 PDFKit으로 문서 보기와 탐색을 구현했습니다. 이후 탭·비교 보기·학습 도구를 추가하고, Apple Vision OCR과 PDFium을 이용한 일부 PDF 본문 편집으로 범위를 넓혔습니다. build 90에서는 대형 PDF의 비동기 저장과 수정한 페이지의 접근성 태그 보존을 집중적으로 검토했습니다. 원본 태그 연결을 확인할 수 없으면 해당 저장을 거부합니다.

### 주요 기능과 기대 효과

- **읽기와 학습.** 여러 문서를 탭으로 관리하고 나란히 비교합니다. 본문을 검색하고 하이라이트, 밑줄, 펜, 메모를 사용할 수 있어 자료를 오가며 검토하는 수고를 줄일 수 있습니다.
- **편집과 정리.** 지원되는 본문 텍스트를 수정하고, 페이지를 재정렬·회전·추출·병합할 수 있습니다. 필요한 부분을 새 PDF로 모으고 저장한 결과를 다시 열어 작업을 이어갈 수 있습니다.
- **OCR과 확장.** Apple Vision으로 스캔 페이지를 인식해 검색 가능한 PDF를 만들 수 있습니다. 번역, 외부 AI, 플러그인은 필요에 따라 설정합니다. 외부 AI를 사용하면 선택한 문맥이 지정한 공급자에게 전송될 수 있습니다.

### 검증 결과와 배포 범위

Apple Silicon과 macOS 15.7.5에서 build 90을 시험했습니다. 전체 XCTest 2788건 중 2754건 통과, 33건 조건부 건너뜀, 1건 실패였습니다. 읽기, 검색, OCR 페이지 선택, 편집, 저장·취소, 페이지 구성, 세션 복원 등을 다시 확인한 195건 중 192건이 통과했고 3건은 별도 입력이 필요한 조건부 검사였습니다. 실제 PDF 30종의 추출·병합과 결과 61개의 비동기 재저장을 확인했고, 선택한 페이지의 렌더링 비교 270쌍에서 픽셀이 일치했습니다.

실패 1건은 PDFKit이 직접 저장한 글꼴에서 권한 정보가 누락된 진단입니다. 앱 저장 경로로 같은 글꼴을 두 차례 저장하고 다시 열었을 때는 권한 정보가 유지됐습니다. 추가 반복 시험에서는 저장 보조 워커의 프로세스 확인이 한 차례 실패했고, 앱의 저장 로직은 이 경우 기존 경로를 사용합니다.

DMG에 포함된 플러그인 헬퍼는 앱과 동일한 샌드박스 권한을 가진 검수용 호스트에서 Ember Recall 검사 6건을 통과했습니다. 이 시험은 명령 등록, 카드 생성과 복습, 원문 페이지 이동 요청, 저장한 카드 복원을 다뤘습니다.

DMG는 Apple Silicon 및 macOS 14 이상을 대상으로 합니다. 체크섬, 마운트, 복사본 서명을 확인했습니다. ad-hoc 서명된 미공증 후보로, 다운로드 후 Finder에서 처음 실행하는 검증은 남아 있습니다. 본문 편집과 OCR 결과는 문서 구조에 따라 달라질 수 있습니다. [macOS 설치 안내](INSTALL-DMG-macOS.txt)

## English

### Purpose

EmberPDF is a macOS workspace for reading, comparing, studying, and editing PDFs. It gives students, researchers, and people who work with documents one place to find passages, annotate source material, and assemble pages from different files. Core reading, search, editing, and OCR run on the Mac. The source is available under the [MPL-2.0](../LICENSE).

EmberPDF continues the project originally released as HwattakPDF. Its earlier source and releases are available in the original GitHub repository. [HwattakPDF](https://github.com/SeederPowerDrop/HwattakPDF)

### Development

The workspace uses SwiftUI and AppKit, with PDFKit for viewing and navigation. Development expanded to tabs, side-by-side reading, study tools, Apple Vision OCR, and PDFium-based editing of supported body text. Build 90 focused on saving large PDFs in the background and preserving accessibility tags on edited pages. The app declines a save when it cannot verify the relevant links in the original tag structure.

### Features and expected benefits

- **Reading and study.** Keep documents in tabs, compare them side by side, search within them, and add highlights, underlines, ink, and notes. These tools can reduce switching between reading and annotation apps.
- **Editing and assembly.** Edit supported body text, reorder or rotate pages, and extract or merge them. Gather the pages you need into a PDF and reopen the saved file for further work.
- **OCR and extensions.** Use Apple Vision to turn scanned pages into searchable PDFs. Configure translation, external AI, and plug-ins as needed. External AI can send selected context to the configured provider.

### Verification and release scope

Build 90 was tested on Apple Silicon with macOS 15.7.5. Of 2,788 XCTest cases, 2,754 passed, 33 were conditionally skipped, and one failed. A focused rerun covering reading, search, OCR page selection, editing, saving and cancellation, page assembly, and session restoration recorded 192 passes and three skips out of 195. Extraction and merging were checked on 30 real PDFs, followed by 61 background resaves. The selected pages matched pixel for pixel in 270 rendering comparisons.

The single full-suite failure concerns missing font permissions metadata when PDFKit writes a file directly. Both save-and-reopen cycles through the app preserved that metadata for the tested font. A separate repeat run captured one intermittent failure to verify a save helper process. The app's save logic uses its existing path in that case.

The plug-in helper included in the DMG passed six Ember Recall checks under a test host with the app’s sandbox entitlements. The checks covered command registration, card creation and review, requests to navigate to the source page, and restoration of saved cards.

The DMG targets Apple Silicon and macOS 14 or later. Its checksum, mount, and copied app signature were checked. It is an ad-hoc-signed, unnotarized candidate. First launch from Finder after download is still pending. Body-text editing and OCR results can vary with the PDF structure. [macOS installation guide](INSTALL-DMG-macOS.txt)

## Français

### Objectif

EmberPDF est un espace de travail macOS pour lire, comparer, étudier et modifier des PDF. Il permet aux étudiants, aux chercheurs et aux personnes qui travaillent régulièrement sur des documents de retrouver des passages, d’annoter leurs sources et de réunir des pages issues de plusieurs fichiers. La lecture, la recherche, la modification et l’OCR de base s’effectuent sur le Mac. Le code source est disponible sous licence [MPL-2.0](../LICENSE).

EmberPDF est le nouveau nom du projet HwattakPDF. Le code et les versions antérieures restent consultables dans le dépôt GitHub d’origine. [HwattakPDF](https://github.com/SeederPowerDrop/HwattakPDF)

### Développement

L’interface s’appuie sur SwiftUI et AppKit. PDFKit assure l’affichage et la navigation. Le projet s’est ensuite enrichi d’onglets, d’une vue côte à côte, d’outils d’étude, de l’OCR avec Apple Vision et de la modification de certains textes avec PDFium. Le build 90 a concentré les efforts sur l’enregistrement des gros PDF en arrière-plan et sur la conservation des balises d’accessibilité des pages modifiées. L’application refuse l’enregistrement si elle ne peut pas vérifier les liens concernés dans la structure de balisage d’origine.

### Fonctions et bénéfices attendus

- **Lecture et étude.** Organiser les documents en onglets, les comparer côte à côte, rechercher du texte, surligner, souligner et ajouter des notes ou des annotations manuscrites. Ces outils peuvent limiter les allers-retours entre applications.
- **Modification et assemblage.** Modifier les textes pris en charge, réordonner, faire pivoter, extraire ou fusionner des pages. Les pages utiles peuvent être réunies dans un PDF, puis rouvertes pour poursuivre le travail.
- **OCR et extensions.** Apple Vision permet de rendre les pages numérisées interrogeables. La traduction, les services d’IA externes et les extensions se configurent selon les besoins. L’IA externe peut transmettre le contexte sélectionné au fournisseur configuré.

### Résultats des tests et périmètre de diffusion

Le build 90 a été testé sur un Mac Apple Silicon équipé de macOS 15.7.5. Sur 2 788 cas XCTest, 2 754 ont réussi, 33 ont été ignorés sous certaines conditions et un a échoué. Un nouvel essai ciblé sur la lecture, la recherche, la sélection des pages OCR, la modification, l’enregistrement et son annulation, l’assemblage des pages et la restauration de session a donné 192 réussites et trois cas ignorés sur 195. L’extraction et la fusion ont été vérifiées sur 30 PDF réels, puis 61 fichiers ont été réenregistrés en arrière-plan. Les pages sélectionnées ont produit des pixels identiques lors de 270 comparaisons de rendu.

L’échec de la suite complète concerne la perte de métadonnées d’autorisation d’une police lors d’un enregistrement direct par PDFKit. Ces métadonnées ont été conservées lors des deux cycles d’enregistrement et de réouverture via l’application avec la police testée. Un essai répété a aussi relevé un échec intermittent de vérification du processus auxiliaire d’enregistrement. Dans ce cas, l’application utilise son circuit d’enregistrement habituel.

Le processus auxiliaire fourni dans le DMG a réussi six tests Ember Recall avec un hôte de test disposant des mêmes droits de bac à sable que l’application. Ces tests ont porté sur l’enregistrement des commandes, la création et la révision de cartes, les demandes de navigation vers la page source et la restauration des cartes enregistrées.

Le DMG vise les Mac Apple Silicon sous macOS 14 ou ultérieur. La somme de contrôle, le montage et la signature de la copie de l’application ont été vérifiés. Le candidat est signé ad hoc et sans notarisation Apple. Le premier lancement dans le Finder après téléchargement reste à vérifier. Les résultats de la modification du texte et de l’OCR dépendent de la structure du PDF. [Guide d’installation macOS](INSTALL-DMG-macOS.txt)

## Русский

### Назначение

EmberPDF — рабочая среда macOS для чтения, сравнения, изучения и редактирования PDF. Студенты, исследователи и другие пользователи могут искать нужные фрагменты, аннотировать материалы и собирать страницы из разных файлов в одном месте. Основные функции чтения, поиска, редактирования и OCR выполняются на Mac. Исходный код доступен по лицензии [MPL-2.0](../LICENSE).

EmberPDF продолжает проект, который первоначально выходил под названием HwattakPDF. Ранние версии и исходный код доступны в первоначальном репозитории на GitHub. [HwattakPDF](https://github.com/SeederPowerDrop/HwattakPDF)

### Разработка

Интерфейс построен на SwiftUI и AppKit, а просмотр и навигация опираются на PDFKit. Затем появились вкладки, просмотр документов рядом, учебные инструменты, OCR на основе Apple Vision и редактирование поддерживаемого текста с помощью PDFium. В сборке 90 основное внимание уделялось фоновому сохранению больших PDF и сохранению тегов доступности на изменённых страницах. Приложение отклоняет сохранение, если не удаётся проверить связи в исходной структуре тегов.

### Возможности и ожидаемая польза

- **Чтение и работа с материалами.** Открывайте документы во вкладках, сравнивайте их рядом, ищите текст, добавляйте выделения, подчёркивания, рукописные пометки и заметки. Это может сократить число переключений между приложениями.
- **Редактирование и сборка.** Изменяйте поддерживаемый текст, меняйте порядок страниц, поворачивайте, извлекайте и объединяйте их. Нужные страницы можно собрать в PDF и снова открыть сохранённый файл для дальнейшей работы.
- **OCR и расширения.** Apple Vision позволяет сделать текст на сканированных страницах доступным для поиска. Перевод, внешние сервисы ИИ и плагины настраиваются по необходимости. При использовании внешнего ИИ выбранный контекст может передаваться настроенному поставщику.

### Результаты тестирования и условия распространения

Сборку 90 тестировали на Mac с Apple Silicon и macOS 15.7.5. Из 2788 тестов XCTest 2754 прошли, 33 были пропущены по условиям, один завершился ошибкой. При повторной проверке чтения, поиска, выбора страниц для OCR, редактирования, сохранения и отмены, сборки страниц и восстановления сеанса прошли 192 из 195 тестов, три были пропущены. На 30 реальных PDF проверили извлечение и объединение страниц, затем 61 результат повторно сохранили в фоновом режиме. Изображения выбранных страниц попиксельно совпали в 270 сравнениях.

Единственная ошибка полного прогона касается метаданных прав на использование шрифта, которые теряются при прямой записи через PDFKit. При двух циклах сохранения и повторного открытия через приложение метаданные проверенного шрифта сохранились. При отдельном повторном испытании один раз не удалось проверить вспомогательный процесс сохранения. В этом случае приложение задействует существующий способ сохранения.

Вспомогательный процесс для плагинов из DMG прошёл шесть проверок Ember Recall под управлением тестового хоста с теми же разрешениями песочницы, что и у приложения. Проверки охватывали регистрацию команд, создание и повторение карточек, запрос на переход к исходной странице и восстановление сохранённых карточек.

DMG предназначен для Mac с Apple Silicon и macOS 14 или новее. Проверены контрольная сумма, монтирование и подпись скопированного приложения. Сборка подписана ad hoc и не прошла нотариальное заверение Apple. Первый запуск в Finder после загрузки ещё предстоит проверить. Результаты редактирования текста и OCR зависят от структуры PDF. [Руководство по установке macOS](INSTALL-DMG-macOS.txt)

## 简体中文

### 项目目标

EmberPDF 是一款用于阅读、对照、学习和编辑 PDF 的 macOS 应用。学生、研究人员和经常处理文档的用户可以在同一工作区查找段落、批注资料，并从多个文件中整理所需页面。基本阅读、搜索、编辑和 OCR 在 Mac 本地运行。源代码采用 [MPL-2.0](../LICENSE) 许可证。

EmberPDF 是原 HwattakPDF 项目的新名称。早期源代码和历史版本可在原 GitHub 仓库中查看。[HwattakPDF](https://github.com/SeederPowerDrop/HwattakPDF)

### 开发过程

工作区使用 SwiftUI 和 AppKit 构建，PDFKit 负责文档显示与导航。随后加入了标签页、并排阅读、学习工具、基于 Apple Vision 的 OCR，以及使用 PDFium 编辑受支持正文的功能。build 90 重点检查了大型 PDF 的后台保存，以及编辑后页面无障碍标签的保留。无法验证原始标签结构中的相关连接时，应用会拒绝该次保存。

### 主要功能与预期收益

- **阅读与学习。** 通过标签页管理文档，进行并排对照和全文搜索，并添加高亮、下划线、手写批注和笔记。这些功能有助于减少在阅读器和批注工具之间切换。
- **编辑与整理。** 可编辑受支持的正文，并对页面进行排序、旋转、提取和合并。用户可以把所需页面整理成一个 PDF，并重新打开已保存的文件继续处理。
- **OCR 与扩展。** 使用 Apple Vision 识别扫描页面，使其可以搜索。翻译、外部 AI 和插件可按需配置。使用外部 AI 时，所选上下文可能发送给已设置的服务提供方。

### 测试结果与发布范围

build 90 在搭载 Apple Silicon、运行 macOS 15.7.5 的 Mac 上进行了测试。共运行 2788 个 XCTest 用例，2754 个通过，33 个按条件跳过，1 个失败。针对阅读、搜索、OCR 页面选择、编辑、保存和取消、页面编排及会话恢复再次检查了 195 个用例，其中 192 个通过，3 个跳过。用 30 份实际 PDF 验证了页面提取和合并，并在后台重新保存了 61 个结果。选定页面在 270 组渲染对比中像素一致。

完整测试中失败的用例涉及 PDFKit 直接写入时丢失的字体权限元数据。使用应用的保存路径，两次保存并重新打开后，被测字体的权限元数据均得以保留。另外，重复测试中有一次未能验证保存辅助进程。出现这种情况时，应用会使用原有保存路径。

DMG 内置的插件辅助进程在具有与应用相同沙盒权限的测试宿主中通过了 6 项 Ember Recall 检查，涵盖命令注册、卡片创建与复习、跳转到原始页面的请求，以及已保存卡片的恢复。

DMG 面向 Apple Silicon Mac，要求 macOS 14 或更高版本。已验证校验和、挂载和应用副本的签名。候选版本采用 ad-hoc 签名，尚未经过 Apple 公证。下载后通过 Finder 首次启动的流程仍待验证。正文编辑和 OCR 的结果会因 PDF 结构而异。[macOS 安装指南](INSTALL-DMG-macOS.txt)
