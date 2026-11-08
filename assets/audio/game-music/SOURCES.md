# Музыка через /game-music: исходники

Сами mp3 (около 115 МБ) в git не лежат. Они есть на ПК в `Desktop\сайты\РПГ\audio\game-music\`
и в приватных артефактах: https://claude.ai/artifact/Ez15v82syiCz9KbFYaPKmJ (`drop/<id>.mp3`, `drop/<id>__alt.mp3`)
и https://claude.ai/artifact/Vj5hkBmGKu8vDmCzoBwjjo (`drop/<id>__v3.mp3`, `drop/<id>__v4.mp3`, вторая попытка).
Чтобы пересобрать OGG, положи их сюда и запусти `python3 tools/audio/import_tracks.py`; какой вариант идёт
в игру, задаёт таблица `USE` в этом скрипте.

## Источник

- **Сервис:** Google Flow Music, https://www.flowmusic.app (чат с ИИ-«продюсером» Producer).
- **Модель:** Lyria 3.5 (инструмент по умолчанию в настройках чата, настройки не менялись).
- **Аккаунт:** Rekviemo, тариф **Plus**.
- **Дата генерации:** 2026-10-27.
- **Сессия:** https://www.flowmusic.app/session/3c1d8022-7611-4e68-92d5-430899f4b6f9 («Dark Medieval Folk Waltz»). Все 17 треков сделаны в ней, чтобы Producer держал общее звучание. Новые треки для этой игры лучше делать там же.
- **Формат файлов:** MP3, 128 кбит/с, скачаны через меню трека Download → MP3. В сервисе исходники хранятся как M4A. Там же бесплатно доступны WAV и стемы, если понадобится качество выше.
- **Потрачено:** 155 кредитов (было 9780, стало 9625). Скачивание бесплатное.
- **Водяной знак:** Lyria встраивает во все треки неслышимый водяной знак SynthID.

## Лицензия и условия

- **Коммерческое использование.** В справке Google One «Use Google AI Plus benefits» (https://support.google.com/googleone/answer/16882689) «Commercial use rights» указаны среди преимуществ тарифа Flow Music Starter. Наш тариф Plus старше Starter. На странице тарифов https://www.flowmusic.app/pricing права на коммерческое использование отдельно не упомянуты.
- **Условия использования.** У сервиса нет отдельного соглашения: ссылка flowmusic.app/terms ведёт на общие Условия использования Google (https://policies.google.com/terms, редакция от 30.07.2026). По ним права на созданный контент остаются у пользователя, Google на оригинальный контент не претендует. Google получает неисключительную лицензию на хранение и обработку контента для работы сервиса.
- **Ограничения.** Действуют «Правила в отношении запрещённого использования генеративного ИИ» (https://policies.google.com/terms/generative-ai/use-policy). В частности, нельзя с целью обмана выдавать ИИ-контент за созданный человеком. Также нельзя использовать результаты для обучения других моделей ИИ.
- **Оговорки.**
  - То, что Google не претендует на права, не значит, что на сгенерированную музыку автоматически возникает охраняемое авторское право: это зависит от юрисдикции.
  - Условия проверены 2026-10-27 и могут измениться. Перед коммерческим релизом их стоит перепроверить и указать в титрах: «Музыка: сгенерирована в Google Flow Music (Lyria)».
  - В аккаунте включена настройка «Help improve Google Flow Music», так что сервис может использовать треки для своего улучшения.

## Общий стиль

Северный средневековый фолк, поздняя осень: акустические инструменты плюс оркестр, без электрогитар, синтезаторов и современной ударной установки. Везде инструментал; где есть хор, он поёт без слов. Каждый промпт после первого ссылается на «the same dark medieval folk RPG», а боссу и прощанию явно задана отсылка к вальсу Ладо (лейтмотив из theme_lado).

## Как выбирался основной вариант

Каждая генерация даёт 2 варианта: основной лежит как `<id>.mp3`, второй как `<id>__alt.mp3`. Слушать треки я не мог, поэтому выбирал по объективным признакам аудио (декодировал его в браузере):
- для петель: совпадение оценки темпа с брифом (с учётом кратности ×2), ровная громкость в середине и отсутствие долгого тихого вступления;
- для стингеров: более короткий трак или тот, у которого в начале есть законченная короткая фраза.

Окончательный выбор стоит сделать на слух.

В трёх генерациях (village, victory, quest) Flow Music показал карточку «Which do you prefer?» с дополнительным бесплатным вариантом. Я нажал «Keep Both», поэтому третий вариант остался в сессии и не скачан.

## Треки

Длительность указана для MP3. Темп в последнем столбце — автоматическая оценка по огибающей, грубая: «—» значит, что темп не определился (эмбиент или стингер).

### Музыка (петли)

| id | Title во Flow Music (основной / alt) | Ссылки | Длит. осн. / alt, с | Темп осн. |
|---|---|---|---|---|
| theme_lado | Lado's Remembrance / Lado's Remembrance (Variation) | [осн.](https://www.flowmusic.app/song/55ec8f7f-5239-4452-9de7-9ec2c09a13fc) · [alt](https://www.flowmusic.app/song/f4427c9c-5138-4dc9-8e3a-bd9f176d1028) | 139.8 / 179.2 | ≈84 |
| funeral | Sunset at the Graveyard (Variation) / Sunset at the Graveyard | [осн.](https://www.flowmusic.app/song/18d0e1b3-ee09-494d-b3a2-c9637fa7ebeb) · [alt](https://www.flowmusic.app/song/6d4481c9-504c-4029-824f-48c9a90774ad) | 179.4 / 175.3 | ≈60 |
| combat_undead | Rising Corpses / Rising Corpses (Variation) | [осн.](https://www.flowmusic.app/song/3d3b46b3-8f69-4c31-9a36-38798e05d24a) · [alt](https://www.flowmusic.app/song/a5a7685d-7dd4-4f1a-92dd-d47a355991ea) | 166.9 / 180.3 | ≈119 |
| village | Dusk at Raven's Ford (Variation) / Dusk at Raven's Ford | [осн.](https://www.flowmusic.app/song/711d15f3-0af4-4591-8a53-19dbf7cc6fc2) · [alt](https://www.flowmusic.app/song/d60b846e-f98d-4622-b96f-a8ed32f1523d) | 179.2 / 150.6 | ≈76 |
| tavern | The Drunken Raven / The Drunken Raven (Variation) | [осн.](https://www.flowmusic.app/song/6fbce295-b710-460b-9e02-f238586b03df) · [alt](https://www.flowmusic.app/song/4d84d14d-3eca-4921-bf26-4fbf095b8f8a) | 179.1 / 122.8 | ≈122 (6/8) |
| forest | Whispering Alders / Whispering Alders (Variation) | [осн.](https://www.flowmusic.app/song/5a23642c-dd21-4c6f-b8e7-afafa40145fe) · [alt](https://www.flowmusic.app/song/8b676179-ea58-47b3-95a5-a2cfe3af9477) | 180.6 / 148.8 | — |
| combat | Blade and Claw (Variation) / Blade and Claw | [осн.](https://www.flowmusic.app/song/70667373-adf5-43d0-b1f3-246c50026ce7) · [alt](https://www.flowmusic.app/song/945643be-3b53-487a-8d10-b155c33138ce) | 169.9 / 166.1 | ≈136 |
| goblin_camp | Marrow and Bone (Variation) / Marrow and Bone | [осн.](https://www.flowmusic.app/song/3bcfc4ea-5058-42a1-910e-910db14d8d13) · [alt](https://www.flowmusic.app/song/609600af-4577-4ec7-b4a8-29547255dd45) | 174.3 / 172.4 | ≈105 |
| boss_lado | Lado's Puppet Dance / Lado's Puppet Dance (Variation) | [осн.](https://www.flowmusic.app/song/8a57895b-9994-484e-a79a-9c5e2b3800a8) · [alt](https://www.flowmusic.app/song/f4334042-660f-4f75-ba91-fd27f1d667e6) | 178.6 / 175.3 | ≈136 |
| farewell | Farewell to Lado / Farewell to Lado (Variation) | [осн.](https://www.flowmusic.app/song/c5fd83c7-0699-4a07-9ab4-61bf3380f92b) · [alt](https://www.flowmusic.app/song/3808d9a8-870f-4403-8675-2e7f110a280d) | 179.6 / 179.8 | ≈74 |
| epilogue | The Priest's House / The Priest's House (Variation) | [осн.](https://www.flowmusic.app/song/94d709ef-0063-4d9d-8bd1-bde28d4c7406) · [alt](https://www.flowmusic.app/song/c93fb1a4-23fd-485f-9863-e601426b7604) | 177.2 / 141.7 | — |

Почему выбран основной вариант:
- **theme_lado:** темп точнее.
- **funeral:** темп 60 и тише, что лучше подходит под диалоги.
- **combat_undead:** темп ближе к 116.
- **village:** темп 76 совпал.
- **tavern:** громкость ровнее, вариант длиннее.
- **forest:** нет тихого вступления.
- **combat:** громкий с первых секунд, а в alt вступление около 40 с.
- **goblin_camp:** громкость ровнее.
- **boss_lado:** громкость ровнее, нет провала посередине.
- **farewell:** темп ближе к 72. В обоих вариантах есть нарастание к концу, как в брифе.
- **epilogue:** громкость ровнее.

Все петли получились длиннее 120 с, так как Lyria почти не слушается по длительности. В конце каждого трека есть затухание.

### Стингеры (одноразовые)

| id | Title во Flow Music (основной / alt) | Ссылки | Длит. осн. / alt, с | Где резать (по огибающей, проверить на слух) |
|---|---|---|---|---|
| omen | Toll of the Dead / Toll of the Dead (Variation) | [осн.](https://www.flowmusic.app/song/a5206b19-0564-4575-b39b-373a53d09119) · [alt](https://www.flowmusic.app/song/51bda7f9-5db7-4530-a9a6-4fcf874a4d85) | 64.8 / 102.2 | явной короткой фразы в начале нет, резать на слух |
| victory | Triumph Fanfare (Variation) / Triumph Fanfare | [осн.](https://www.flowmusic.app/song/233ee3ec-e680-4b68-ae7c-f93a7fb22474) · [alt](https://www.flowmusic.app/song/2fe6dba4-c243-4418-a9ed-cd0937fb4612) | 59.4 / 120.0 | звук начинается примерно с 1 с, тишины в начале нет |
| defeat | Fallen in Darkness / Fallen in Darkness (Variation) | [осн.](https://www.flowmusic.app/song/5c68c42d-f9bf-4d86-8ae7-3502524c6d1b) · [alt](https://www.flowmusic.app/song/8d773cee-c481-4b6d-838e-f85b239dc822) | 61.1 / 56.3 | законченная фраза примерно 0–12 с с затуханием к 12 с |
| level_up | Ascension Chime (Variation) / Ascension Chime | [осн.](https://www.flowmusic.app/song/f7c8bc56-b908-4e4c-8824-7b52a4198345) · [alt](https://www.flowmusic.app/song/93b81062-6b11-48c7-9ca6-420c7b051f1a) | 61.5 / 30.4 | фраза примерно 1–6 с, потом провал |
| quest | Whisper of Fate (Variation) / Whisper of Fate | [осн.](https://www.flowmusic.app/song/eaeab975-9043-47e4-943d-4f738439220a) · [alt](https://www.flowmusic.app/song/cb664031-e423-4a55-b111-0761eeec5754) | 61.9 / 67.1 | звучит сразу, явной короткой фразы нет, нужен фейд |
| quest_done | Deed Accomplished / Deed Accomplished (Variation) | [осн.](https://www.flowmusic.app/song/5c5d5666-a008-4ab1-97f3-5d3ac3d015bf) · [alt](https://www.flowmusic.app/song/fed93900-2366-41c6-bf4f-ea5a014a8984) | 62.7 / 62.4 | звучит сразу, фраза примерно 0–8 с |

Lyria проигнорировала просьбу о длительности 3–10 с: стингеры получились по 30–100 с, и их нужно обрезать. Третьи варианты, которые остались только в сессии:
- village: https://www.flowmusic.app/song/760c39c4-f320-4457-a449-82c8fbf7cb37
- victory: https://www.flowmusic.app/song/87505605-f0e8-4a81-b730-0aa835ce70e9
- quest: https://www.flowmusic.app/song/da5d1567-879a-4d62-b12a-fec5193ba627

## Промпты (отправлены Producer дословно)

Producer переписывал каждый промпт в карточку «Sound» (теги на английском) и по ней генерировал трек.

- **theme_lado:** Instrumental only, no vocals. Main menu theme for a dark medieval folk RPG set in a northern village in late autumn: the leitmotif of Lado, the hero's fallen friend. A warm, melancholic and nostalgic folk waltz in 3/4 time. A solo fiddle carries a simple, memorable melody, a nylon-string lute plays gentle arpeggios, a soft cello sings a countermelody, and a harp adds shimmering accents. D dorian, 84 BPM. Steady, intimate energy throughout, no big intro and no dramatic ending, so it can loop seamlessly. No electric guitars, synths or modern drums. About 2 minutes long.
- **funeral:** Instrumental only, no sung words. Funeral music for the opening scene of the same dark medieval folk RPG: a burial at an old village graveyard at sunset. Slow 3/4 time, 60 BPM, D minor. A distant church bell tolls now and then, a soft wordless choir hums sustained 'ooh' chords with no lyrics, a solo cello plays a grieving melody over a low string drone. Quiet, restrained and sparse, leaving space for dialogue on top. Calm and even throughout, no big intro, no climax and no ending, so it can loop seamlessly. No drums, electric guitars or synths. About 2 minutes long.
- **combat_undead:** Instrumental only, no vocals. Battle music against the undead in the same dark medieval folk RPG: corpses rising from a cursed graveyard. Tense and dark: a driving low string ostinato, a church organ with ominous chords, trombones, pounding timpani, tubular bells, and dissonant tremolo violins. D phrygian, 116 BPM. Full energy from the first second, no long intro and no ending, so it can loop seamlessly. No electric guitars, synths or modern drum kits. About 2 minutes long.
- **village:** Instrumental only, no vocals. Exploration music for Raven's Ford, a small northern village at dusk the day after a tragedy, in the same dark medieval folk RPG. Cozy but uneasy: nylon-string lute arpeggios, a clarinet and a wooden flute share a gentle melody, soft strings underneath with an occasional uneasy tremolo. A minor, 76 BPM. Steady energy throughout, no big intro and no dramatic ending, so it can loop seamlessly. No electric guitars, synths or modern drums. About 2 minutes long.
- **tavern:** Instrumental only, no vocals. Tavern music for the Drunken Raven inn in the same medieval folk RPG. A fast, rowdy and cheerful folk jig in 6/8: fiddle and tin whistle play the lively tune, an accordion and a strummed acoustic guitar keep the harmony, bodhran and tambourine drive the rhythm. D major. Full energy from the first second, no long intro and no ending, so it can loop seamlessly. No electric guitars, synths or modern drum kits. About 2 minutes long.
- **forest:** Instrumental only, no vocals. Exploration music for a misty, swampy alder forest in the same dark medieval folk RPG. Dark ambient, misty and mysterious: warm soft pads, bowed string drones, a breathy wooden flute in a shakuhachi-like style and a recorder playing sparse phrases, and occasional kalimba notes falling like water drops. D minor, 56 BPM, slow and spacious. Calm and even throughout, no intro and no ending, so it can loop seamlessly. No drums, electric guitars or synth leads. About 2 minutes long.
- **combat:** Instrumental only, no vocals. Battle music for ordinary fights against wolves, drowned dead and goblins in the same dark medieval folk RPG. An energetic folk battle: taiko and frame drums pound, a staccato string ostinato drives forward, a fiddle and French horns carry a heroic melody, and brass hits punctuate the phrases. E dorian, 138 BPM. Full energy from the first second, no long intro and no ending, so it can loop seamlessly. No electric guitars, synths or modern drum kits. About 2 minutes long.
- **goblin_camp:** Instrumental only, no sung lyrics. Music for a goblin camp on an ancient burial mound in the same dark medieval folk RPG. Comic and sinister at once: a staccato bassoon, pizzicato strings, a tuba bass line, tribal drums and woodblocks, and a grunting tribal chant of nonsense syllables with no real words. D phrygian, 100 BPM. Steady energy throughout, no big intro and no dramatic ending, so it can loop seamlessly. No electric guitars, synths or modern drum kits. About 2 minutes long.
- **boss_lado:** Instrumental only, no sung lyrics. Boss battle music in the same dark medieval folk RPG: a goblin shaman drives the walking corpse of the hero's dead friend Lado into battle. A grotesque danse macabre waltz in 3/4 at 138 BPM: a distorted minor-key version of Lado's folk waltz, with a xylophone rattling like bones and a sly bassoon, then growing into full brass, church organ, a wordless choir with no lyrics, and pounding timpani. Grotesque and epic, D minor. Full energy from the start, no long intro and no ending, so it can loop seamlessly. No electric guitars, synths or modern drum kits. About 2 minutes long.
- **farewell:** Instrumental only, no sung lyrics. Music for a funeral pyre and the farewell to the ghost of the hero's friend Lado, the emotional climax of the same dark medieval folk RPG. 3/4 time, 72 BPM. It begins intimate in D minor with a solo violin, a harp and a nylon-string guitar, echoing Lado's folk waltz, slowly builds to a full orchestra with French horns and a wordless choir with no lyrics, and turns to D major at the end. Bittersweet and hopeful. No electric guitars, synths or modern drums. About 2 minutes long.
- **epilogue:** Instrumental only, no vocals. Epilogue music for the same dark medieval folk RPG: the hero walks into the empty house of the village priest, and something is very wrong. Quiet, ominous dark ambient: low drones, sparse celesta notes, and a single distant bell toll. D minor, 50 BPM, very slow and spacious. Quiet and even throughout, no intro and no ending, so it can loop seamlessly. No drums, electric guitars or synth leads. About 2 minutes long.
- **omen:** Instrumental only, no sung words. A very short horror stinger, about 10 seconds, for the same dark medieval folk RPG: during the funeral the church bell tolls by itself twice, the earth rumbles, a dissonant wordless choir and tremolo strings swell and end in one huge orchestral hit, then silence. Keep it as short as possible, not a full song.
- **victory:** Instrumental only, no vocals. A very short victory fanfare, about 5 seconds, played after winning a battle in the same medieval folk RPG: folk-flavoured brass and timpani, D major, ending on a strong final chord. Keep it as short as possible, not a full song.
- **defeat:** Instrumental only, no vocals. A very short defeat jingle, about 10 seconds, for the same dark medieval folk RPG: a slow descending French horn line over strings, D minor, sad, ending quietly. Keep it as short as possible, not a full song.
- **level_up:** Instrumental only, no vocals. A very short level-up jingle, about 3 seconds, for the same medieval folk RPG: a harp glissando, bright bells and a bright major chord. Keep it as short as possible, not a full song.
- **quest:** Instrumental only, no vocals. A very short 'new quest' jingle, about 4 seconds, for the same dark medieval folk RPG: harp and flute, mysterious, D minor. Keep it as short as possible, not a full song.
- **quest_done:** Instrumental only, no vocals. A very short 'quest completed' jingle, about 4 seconds, for the same medieval folk RPG: brass, harp and glockenspiel, D major, bright and satisfying. Keep it as short as possible, not a full song.

## Вторая попытка (2026-10-28)

Переделаны 4 трека, которые не понравились: funeral, combat_undead, tavern, combat. Сервис, модель, аккаунт и сессия те же: Google Flow Music, Lyria 3.5, https://www.flowmusic.app/session/3c1d8022-7611-4e68-92d5-430899f4b6f9. Старые файлы (`<id>.mp3`, `<id>__alt.mp3`) не тронуты. Новые лежат рядом как `<id>__v3.mp3` и `<id>__v4.mp3`.

- **Потрачено:** 40 кредитов (было 9655, стало 9615). Cover по образцу стоит 5 кредитов и даёт **1** трек, поэтому на funeral, combat_undead и combat ушло по два cover (2 × 5 = 10). Обычная генерация tavern (2 варианта) стоила 10.
- **Образцы.** У Flow Music есть загрузка своего аудио (кнопка `+` → «Upload audio file» у поля чата). С загруженным файлом Producer сам выбирает режим **Cover**: переигрывает трек, сохраняя его длину и структуру. Для funeral, combat_undead и combat образцом служили мои прежние версии, написанные кодом: приватный артефакт https://claude.ai/artifact/7PedHKKYYcqviMy4eNPwJp, файлы `music/funeral.mp3` (72.0 с, sha256 `8a1affffc80e923dfe8e06afcba991e22a5731ae6e8d0d09fd231878a0262836`), `music/combat_undead.mp3` (66.2 с, `08b09c5e6e08aeffe7cd766f17db70931c7db7ac0a2d41545f70f68d41c59346`) и `music/combat.mp3` (55.7 с, `307aa5ed6d17310f1df60dc237df94363d79d5dabede565c2aca977e4b9d8930`). Для v4 файл загружался заново и отправлялся тот же промпт. Таверна сделана без образца, обычной генерацией. Загруженные образцы остались в аккаунте Flow Music.
- **Длительность.** Cover повторяет длину образца, поэтому funeral, combat_undead и combat получились по 56–72 с, а не ~2 минуты, как в промпте. Таверна вышла 178 с.
- **Слушать я не мог** (звук на ПК был выключен). Проверял декодированием в браузере без воспроизведения.

### Треки

| файл | Title во Flow Music | ссылка | длит., с | образец | громкость и петля (по огибающей) |
|---|---|---|---|---|---|
| funeral__v3.mp3 | Authentic Acoustic Funeral Waltz | https://www.flowmusic.app/song/45f9ad8f-942d-41d8-9b28-39df6b2f168f | 72.0 | да, cover | звучит с 0 с, к концу затухание около 2 с |
| funeral__v4.mp3 | acoustic cover | https://www.flowmusic.app/song/7b32ef85-5036-40ad-aca6-0c24ce0a876f | 72.0 | да, cover | звучит с 0 с, к концу затухание около 6 с |
| combat_undead__v3.mp3 | combat_undead_acoustic | https://www.flowmusic.app/song/32d651cd-0759-467c-958e-24347c4d1e4d | 65.4 | да, cover | ровно от начала до конца, затухания нет |
| combat_undead__v4.mp3 | acoustic combat_undead | https://www.flowmusic.app/song/e2e3c3b5-cbad-47f0-896b-f520b77aa219 | 66.2 | да, cover | ровно, в последние 1.5 с громче (−15 дБ при медиане −20) |
| combat__v3.mp3 | combat (Acoustic Folk Re-performance) | https://www.flowmusic.app/song/226b0c81-bcc5-49ca-abd4-3c77ef849330 | 55.7 | да, cover | ровно от начала до конца, затухания нет |
| combat__v4.mp3 | combat (acoustic cover) | https://www.flowmusic.app/song/3d010271-2f29-4d7b-9d42-ee4dfb0f5c8b | 55.7 | да, cover | ровно от начала до конца, затухания нет |
| tavern__v3.mp3 | Evening at the Drunken Raven | https://www.flowmusic.app/song/d768078e-8d74-41d4-8611-e0a0c86c41c9 | 178.4 | нет | ровно до ~171.5 с, дальше затухание; для петли резать около 171 с |
| tavern__v4.mp3 | Evening at the Drunken Raven (Variation) | https://www.flowmusic.app/song/0b28c7b8-8ccd-485b-85b5-fe424603873e | 178.1 | нет | ровно до ~172.5 с, дальше затухание; для петли резать около 172 с |

Все MP3 скачаны через меню трека Download → MP3, 128 кбит/с.

### Насколько cover похож на образец

Сравнивал хромаграммы (какие ноты звучат в каждые 0.25 с) и огибающую атак. «Синхронно» значит сходство кадр в кадр с образцом. «Перемешано» значит то же, но со сдвигом на полтрека, это базовый уровень одной тональности без общей мелодии. Чем больше разница, тем точнее cover идёт за гармонией образца во времени.

| трек | синхронно | перемешано | тональность | ритм (атаки) |
|---|---|---|---|---|
| funeral v3 | 0.82 | 0.59 | совпадает (r = 0.99) | у медленной легатной музыки атаки слабые, оценка не информативна |
| funeral v4 | 0.79 | 0.59 | совпадает (r = 0.95) | то же |
| combat_undead v3 | 0.79 | 0.76 | близкая (r = 0.82, лучший сдвиг на 7 полутонов) | с образцом не совпадает (r = 0.06), темп не определился |
| combat_undead v4 | 0.84 | 0.79 | совпадает (r = 0.83) | с образцом не совпадает (r = 0.04), темп не определился |
| combat v3 | 0.82 | 0.80 | совпадает (r = 0.81) | совпадает с образцом (r = 0.46 без сдвига), темп ≈139, как у образца |
| combat v4 | 0.74 | 0.71 | ушла (r = 0.63, лучший сдвиг на 5 полутонов) | темп ≈139, но рисунок другой (r = 0.08) |

Вывод: оба funeral явно повторяют гармонию образца, combat v3 повторяет и темп, и ритм. combat v4 и оба combat_undead обращаются с образцом свободнее. Оценка грубая, окончательно выбирать на слух.

### Промпты (отправлены Producer дословно)

Общий хвост S (в конце каждого промпта):

> Style: like a classic late-90s isometric CRPG soundtrack: one clear, simple, memorable melody on a solo instrument over a modest ensemble; plain and honest, close to folk; not a cinematic trailer, no epic wall of sound, no booming hits, no modern production; acoustic and orchestral instruments only, no synths, no electric guitars, no modern drum kit. Even energy throughout, no long intro and no ending, so it loops seamlessly. About 2 minutes long.

Для v3 и v4 отправлялся один и тот же текст.

- **funeral** (+ образец funeral.mp3): Use the attached audio as the reference: keep its mood, melody, harmony and instruments, but re-perform it as a real acoustic recording by live musicians, more alive, richer and more expressive, at the same slow tempo. Instrumental, wordless choir only, no lyrics. Funeral of the hero's friend Lado at an old village graveyard at sunset, the opening scene of a dark medieval folk RPG. Slow 3/4 waltz, 60 BPM, D minor. A solo cello plays a plain, sorrowful folk waltz melody (Lado's theme from the main menu waltz) over a soft reed organ and a low string pad with a double bass on the roots; in the second half a soft wordless 'ooh' choir takes the melody and the cello moves to a low countermelody; one deep church bell tolls rarely. Quiet and hymn-like, like a village lament, leaving space for dialogue. No percussion. + S
- **combat_undead** (+ образец combat_undead.mp3): Use the attached audio as the reference: keep its mood, melody, harmony and instruments, but re-perform it as a real acoustic recording by live musicians, more alive, richer and more expressive, at the same tempo. Instrumental only. Fight against the undead rising from a cursed village graveyard in the same dark medieval folk RPG. 4/4, 116 BPM, D phrygian. A relentless low string ostinato built on the minor second (D and E-flat), a church organ holding dark chords, trombones stating a short grim motif, tubular bells on the downbeats, tense tremolo violins on top. Dark and driving but clear and readable, like a classic RPG battle theme, not a horror soundscape. + S
- **tavern** (без образца): Instrumental only. Background music for the Drunken Raven, a small backwater village tavern on the evening after a funeral, in the same dark medieval folk RPG. Relaxed and modest, a little weary and wistful but warm; not festive, not cheerful, not childish, and not sad either. Slow walking pace, about 90 BPM, 3/4, D dorian. A plucked lute keeps simple chords, a fiddle and a low whistle trade a calm, plain folk tune, a frame drum taps softly, an accordion adds a quiet drone now and then. A small band of three or four players in the corner of a quiet tavern. + S
- **combat** (+ образец combat.mp3): Use the attached audio as the reference: keep its mood, melody, harmony and instruments, but re-perform it as a real acoustic recording by live musicians, more alive, richer and more expressive, at the same tempo. Instrumental only. Battle music for ordinary fights against wolves, drowned dead and goblins in the same dark medieval folk RPG. 4/4, 138 BPM, E dorian. Taiko and low toms keep a steady pounding pattern, staccato strings drive an ostinato, a fiddle and French horns carry a heroic folk melody in call and response, short brass hits only at phrase peaks. Energetic and catchy like a classic RPG battle theme, but grounded and folk, not bombastic Hollywood. + S

### Как Producer переписал промпты

- **funeral v3:** Re-perform this track as an authentic, organic acoustic recording by live musicians. Funeral music for Lado at an old village graveyard at sunset, opening scene of a dark medieval folk RPG. Slow 3/4 waltz, 60 BPM, D minor. Solo cello plays the sorrowful folk waltz melody (Lado's theme) over soft reed organ and low string pad with double bass. In the second half, a soft wordless ooh choir takes the lead melody while cello moves to low countermelody, with a rare deep church bell tolling. Quiet, hymn-like, classic late-90s isometric CRPG soundtrack style, warm and expressive folk ensemble, no percussion, no synths, no electric guitars. Seamless looping atmosphere.
- **funeral v4:** то же, но без упоминания Lado.
- **combat_undead v3 и v4:** Re-perform this track as an authentic, organic acoustic recording by live musicians. Undead battle theme for a dark medieval folk RPG in D phrygian at 116 BPM. Relentless low string ostinato on D and E-flat, church organ holding dark chords, trombones stating a short grim motif, tubular bells on downbeats, tense tremolo violins on top. Pounding timpani and frame drums. Classic late-90s isometric CRPG soundtrack style, clear and readable battle theme, no synths, no electric guitars, no modern drum kit. Seamless looping atmosphere. Литавры и рамочные барабаны Producer добавил сам, в промпте их не было.
- **combat v3 и v4:** Re-perform this track as an authentic, organic acoustic recording by live musicians. Standard battle theme for a dark medieval folk RPG in E dorian at 138 BPM. Taiko and frame drums keep a steady pounding pattern, staccato strings drive an ostinato, fiddle and French horns carry a heroic folk melody in call-and-response, short brass hits accent phrase peaks. Classic late-90s isometric CRPG soundtrack style, grounded folk feel, no synths, no electric guitars, no modern drum kit. Seamless looping atmosphere.
- **tavern (карточка Sound):** dark medieval folk RPG tavern background theme, Drunken Raven inn on a quiet evening after a funeral, relaxed weary wistful warm atmosphere, slow walking 3/4 waltz, 90 bpm, D dorian, plucked lute simple chords, fiddle and low whistle trading a calm plain folk tune, soft frame drum taps, subtle accordion drone, small modest ensemble of live acoustic players, classic late-90s isometric CRPG soundtrack style, clear memorable folk melody, seamless looping, no electric guitars, no synths, no modern drum kit
