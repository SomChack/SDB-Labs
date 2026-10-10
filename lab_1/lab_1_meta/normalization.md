# Лаба 1. Нормализация данных `ships_data.json` (1НФ → 2НФ → 3НФ → НФБК)

Во всех таблицах: **жирным** выделены атрибуты первичного ключа, `→` обозначает внешний ключ. Время везде в UTC. Значения `eta` оставлены как в JSON (миллисекунды от эпохи), конвертация делается в загрузчике.

---

## 0. Исходные данные (0НФ)

В JSON 10 записей, но судов всего 7. CORAL, BALTIC PIONEER и SOUTHERN STAR встречаются дважды, с разным временем и координатами. Это разные сигналы одного судна, то есть ретроспектива перемещений, которую требует README.

### Атрибуты исходной записи (28 штук)

`imo, mmsi, callSign, name, nameLat, flag, сountry, shipTypeName, seaTypes, seaAreaKm, sea, countryFollow, source, exitPort, exitPortCountry, destinationPort, destinationPortCountry, eta, supervisorCompany, supervisor, receiveDate, navStatus, latitude, longitude, course, speed, rot, heading`

### Проблемы исходной структуры

- `seaTypes` — список в одной ячейке (`"['military','trade']"`), нарушение атомарности.
- Данные судна повторяются в каждой записи (CORAL 2 раза, BALTIC PIONEER 2 раза, SOUTHERN STAR 2 раза).
- Площадь акватории, страна порта, компания оператора дублируются текстом.
- Нужен ключ, который различает записи.

### Функциональные зависимости (ФЗ), выявленные по данным и описаниям полей

| № | ФЗ | Комментарий |
|---|---|---|
| F1 | `imo` → mmsi, callSign, name, nameLat, flag, сountry, shipTypeName | Свойства самого судна |
| F2 | `mmsi` → imo; `callSign` → imo | Идентификаторы однозначны, значит это альтернативные ключи судна |
| F3 | `sea` → seaAreaKm, seaTypes | Для одного моря значения всегда одинаковы (Barents Sea → 1424000 у SADIE и ARCTIC EXPLORER) |
| F4 | `exitPort` → exitPortCountry; `destinationPort` → destinationPortCountry | Страна — свойство порта (допущение на тестовых данных, см. ниже) |
| F5 | `supervisor` → supervisorCompany | Оператор работает в одной компании (допущение) |
| F6 | рейс → exitPort, destinationPort, countryFollow, eta, supervisor | План плавания, не меняется между сигналами |
| F7 | (рейс, `receiveDate`) → source, sea, navStatus, latitude, longitude, course, speed, rot, heading | Состояние на момент сигнала |

> Допущения F4 и F5: на 7 тестовых судах название порта и ФИО оператора однозначно определяют страну и компанию. В реальных данных название порта неуникально (есть Sydney в Австралии и в Канаде), поэтому на стадии НФБК вводятся суррогатные ключи.

---

## 1. Первая нормальная форма (1НФ)

**Требование:** все значения атомарны, нет повторяющихся групп, есть первичный ключ.

**Что нарушено:** поле `seaTypes` содержит список.

**Что сделано:**

1. Список `seaTypes` вынесен в отдельное отношение `SEA_TYPE` (по одной строке на пару «море — назначение»). Так ячейка перестаёт быть множеством, а дубли пары запрещены ключом.
2. Для основной таблицы `REPORT_1NF` выбран первичный ключ `(imo, receive_date)`: судно плюс момент сигнала однозначно определяют запись.
3. Остальные 27 атрибутов (кроме `seaTypes`) остаются в `REPORT_1NF` без изменений.

### Таблица `REPORT_1NF`

Ключ: **(imo, receive_date)**. Показаны ключевые столбцы и по одному «представительному» из каждой группы. Остальные столбцы (mmsi, call_sign, name_lat, flag, country, follow, source, exit_port_country, destination_port_country, eta, supervisor_company, lat, lon, course, rot, heading) заполнены значениями из JSON.

| **imo** | **receive_date** | name | ship_type | sea | sea_area_km | exit_port | destination_port | supervisor | nav_status | speed |
|---|---|---|---|---|---|---|---|---|---|---|
| 8841917 | 2023-09-09 17:07:28 | SADIE | Tanker | Barents Sea | 1424000 | KHATANGA | BETHEL | Sidorov Ivan Ivanovich | At Anchor | 0.0 |
| 9841931 | 2023-09-09 19:00:00 | ADVENTURER | Cruise | Atlantic Ocean | 1120000 | TORONTO | OSLO | Anna Maria Johnson | Moored | 4 |
| 8841920 | 2023-09-09 18:00:00 | CORAL | Cargo | North Sea | 1300000 | VALDEZ | FALMOUTH | John Doe Smith | Underway using engine | 3 |
| 9841932 | 2023-09-09 20:00:00 | BALTIC PIONEER | Container Ship | Baltic Sea | 1030000 | HAMBURG | GDANSK | Lars Müller | Underway using engine | -12 |
| 9841933 | 2023-09-09 21:00:00 | OCEAN TRAVELLER | Cruise | Mediterranean Sea | 1100500 | GENOA | BARCELONA | Giuseppe Verdi | Underway using engine | 14 |
| 9841934 | 2023-09-09 22:00:00 | ARCTIC EXPLORER | Research Vessel | Barents Sea | 1424000 | MURMANSK | STOCKHOLM | Alexei Ivanov | Underway using engine | 16 |
| 9841935 | 2023-09-09 23:00:00 | SOUTHERN STAR | Cargo | Tasman Sea | 930000 | SYDNEY | WELLINGTON | Emily Johnson | Underway using engine | 18 |
| 8841920 | 2023-09-09 20:00:00 | CORAL | Cargo | North Sea | 1300000 | VALDEZ | FALMOUTH | John Doe Smith | Underway using engine | 3 |
| 9841932 | 2023-09-09 22:13:00 | BALTIC PIONEER | Container Ship | Baltic Sea | 1030000 | HAMBURG | GDANSK | Lars Müller | Underway using engine | -12 |
| 9841935 | 2023-09-09 23:15:13 | SOUTHERN STAR | Cargo | Tasman Sea | 930000 | SYDNEY | WELLINGTON | Emily Johnson | Underway using engine | 18 |

### Таблица `SEA_TYPE` (1НФ)

Ключ: **(sea, sea_type)**

| **sea** | **sea_type** |
|---|---|
| Barents Sea | military |
| Barents Sea | trade |
| Atlantic Ocean | commercial |
| Atlantic Ocean | tourism |
| North Sea | research |
| North Sea | trade |
| Baltic Sea | commercial |
| Baltic Sea | trade |
| Mediterranean Sea | tourism |
| Mediterranean Sea | cruise |
| Tasman Sea | commercial |
| Tasman Sea | trade |

**Что осталось плохо** (исправляется на следующих шагах): данные судна повторяются в каждой строке (CORAL, BALTIC PIONEER, SOUTHERN STAR по 2 раза). Это аномалия обновления: чтобы сменить позывной CORAL, надо править две строки.

---

## 2. Вторая нормальная форма (2НФ)

**Требование:** 1НФ и каждый неключевой атрибут зависит от **всего** ключа, а не от его части.

**Что нарушено** (частичные зависимости от составного ключа `(imo, receive_date)`):

- По F1 атрибуты судна зависят только от `imo`, а не от `receive_date`.
- По F6 атрибуты плавания (порты, ETA, оператор, `countryFollow`) зависят от рейса, а не от момента сигнала.

**Что сделано:**

1. Выделена таблица `SHIP` с ключом `imo`.
2. Введён рейс `VOYAGE` с суррогатным ключом `voyage_id`. В JSON у рейса нет идентификатора, а судно может совершать много рейсов, поэтому `voyage_id` нужен. Атрибуты плавания переехали в него.
3. В `REPORT` остались только атрибуты, зависящие от момента сигнала. Ключ стал `(voyage_id, receive_date)`.
4. `SEA_TYPE` без изменений (ключ `(sea, sea_type)`, неключевых атрибутов нет, значит нарушений нет).

### Таблица `SHIP` (2НФ)

Ключ: **imo**

| **imo** | mmsi | call_sign | name | name_lat | flag | owner_country | ship_type_name |
|---|---|---|---|---|---|---|---|
| 8841917 | 368346000 | WDJ5676 | SADIE | SADIE | USA | USA | Tanker |
| 9841931 | 377346200 | KLD4921 | ADVENTURER | ADVENTURER | CAN | CAN | Cruise |
| 8841920 | 368346010 | WDJ5679 | CORAL | CORAL | UK | UK | Cargo |
| 9841932 | 377346201 | KLD4922 | BALTIC PIONEER | BALTIC PIONEER | GER | GER | Container Ship |
| 9841933 | 377346202 | KLD4923 | OCEAN TRAVELLER | OCEAN TRAVELLER | ITA | ITA | Cruise |
| 9841934 | 377346203 | KLD4924 | ARCTIC EXPLORER | ARCTIC EXPLORER | RUS | RUS | Research Vessel |
| 9841935 | 377346204 | KLD4925 | SOUTHERN STAR | SOUTHERN STAR | AUS | AUS | Cargo |

### Таблица `VOYAGE` (2НФ)

Ключ: **voyage_id**. Внешний ключ: `imo → SHIP`.

| **voyage_id** | imo | exit_port | exit_port_country | destination_port | destination_port_country | follow_country | eta | supervisor | supervisor_company |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 8841917 | KHATANGA | USA | BETHEL | USA | CAN | 1695319505000 | Sidorov Ivan Ivanovich | ShipVising inc. |
| 2 | 9841931 | TORONTO | CAN | OSLO | NOR | NOR | 1695319605000 | Anna Maria Johnson | AtlanticKeeper Inc. |
| 3 | 8841920 | VALDEZ | USA | FALMOUTH | UK | AUS | 1695318605000 | John Doe Smith | OceanGuardian Ltd. |
| 4 | 9841932 | HAMBURG | GER | GDANSK | POL | POL | 1695318626000 | Lars Müller | BalticShipping Ltd. |
| 5 | 9841933 | GENOA | ITA | BARCELONA | ESP | ESP | 1697911505000 | Giuseppe Verdi | MediterraneanCruises Inc. |
| 6 | 9841934 | MURMANSK | RUS | STOCKHOLM | SWE | SWE | 1697911505000 | Alexei Ivanov | PolarResearch Corp. |
| 7 | 9841935 | SYDNEY | AUS | WELLINGTON | NZ | NZ | 1697911505000 | Emily Johnson | AustralisShipping Ltd. |

### Таблица `REPORT` (2НФ)

Ключ: **(voyage_id, receive_date)**. Внешний ключ: `voyage_id → VOYAGE`.

| **voyage_id** | **receive_date** | source | sea | sea_area_km | nav_status | latitude | longitude | course | speed | rot | heading |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2023-09-09 17:07:28 | EXACTEARTH | Barents Sea | 1424000 | At Anchor | 60.76969 | -161.75143 | 282.6 | 0.0 | 0.0 | 9 |
| 2 | 2023-09-09 19:00:00 | SHIPFINDER | Atlantic Ocean | 1120000 | Moored | 52.46592 | -142.69320 | 272.8 | 4 | 2 | 18 |
| 3 | 2023-09-09 18:00:00 | OCEANTRACKER | North Sea | 1300000 | Underway using engine | 54.76960 | -152.75130 | 280.1 | 3 | 1 | 12 |
| 3 | 2023-09-09 20:00:00 | OCEANTRACKER | North Sea | 1300000 | Underway using engine | 54.77960 | -152.77130 | 280.1 | 3 | 1 | 12 |
| 4 | 2023-09-09 20:00:00 | SHIPFINDER | Baltic Sea | 1030000 | Underway using engine | 53.50192 | -141.69320 | 270.0 | -12 | 0 | 272 |
| 4 | 2023-09-09 22:13:00 | SHIPFINDER | Baltic Sea | 1030000 | Underway using engine | 53.51192 | -141.70120 | 270.0 | -12 | 0 | 272 |
| 5 | 2023-09-09 21:00:00 | EXACTEARTH | Mediterranean Sea | 1100500 | Underway using engine | 43.80171 | 7.69320 | 88.0 | 14 | 0 | 90 |
| 6 | 2023-09-09 22:00:00 | EXACTEARTH | Barents Sea | 1424000 | Underway using engine | 68.96192 | 33.09320 | 330.0 | 16 | 0 | 334 |
| 7 | 2023-09-09 23:00:00 | OCEANTRACKER | Tasman Sea | 930000 | Underway using engine | -33.86985 | 151.20930 | 150.0 | 18 | 0 | 152 |
| 7 | 2023-09-09 23:15:13 | OCEANTRACKER | Tasman Sea | 930000 | Underway using engine | -33.85985 | 151.21930 | 150.0 | 18 | 0 | 152 |

### Таблица `SEA_TYPE` (2НФ)

Без изменений, как в 1НФ.

**Что осталось плохо:** в `VOYAGE` страна порта зависит от порта, а компания от оператора. В `REPORT` площадь моря зависит от моря (`Barents Sea → 1424000` повторяется). Это транзитивные зависимости.

---

## 3. Третья нормальная форма (3НФ)

**Требование:** 2НФ и нет транзитивных зависимостей (неключевой атрибут не зависит от другого неключевого).

**Что нарушено:**

| Таблица | Транзитивная зависимость | Цепочка |
|---|---|---|
| `VOYAGE` | `exit_port → exit_port_country` | voyage_id → exit_port → exit_port_country |
| `VOYAGE` | `destination_port → destination_port_country` | voyage_id → destination_port → destination_port_country |
| `VOYAGE` | `supervisor → supervisor_company` | voyage_id → supervisor → supervisor_company |
| `REPORT` | `sea → sea_area_km` | (voyage_id, receive_date) → sea → sea_area_km |

**Что сделано:**

1. Из `VOYAGE` выделены `PORT` и `SUPERVISOR`. Страна порта хранится один раз. Поля `exit_port_country` и `destination_port_country` удалены, так как выводятся через порт. Порт выхода и порт назначения — одна и та же сущность `PORT` в двух ролях.
2. Из `REPORT` выделена `SEA_AREA(sea, area_km)`. Колонка `sea_area_km` удалена. Таблица `SEA_TYPE` теперь ссылается на `SEA_AREA`.
3. `SHIP` не менялась: `ship_type_name`, `flag`, `owner_country` ничего не определяют, транзитивных зависимостей нет.

> `follow_country` в `VOYAGE` **не выводится** из порта назначения (у SADIE это CAN при порте в USA, у CORAL AUS при порте в UK). Поэтому это самостоятельный атрибут, и он остаётся в `VOYAGE`.

### Таблица `SHIP` (3НФ)

Без изменений, как в 2НФ.

### Таблица `VOYAGE` (3НФ)

Ключ: **voyage_id**. Внешние ключи: `imo → SHIP`, `exit_port, destination_port → PORT`, `supervisor → SUPERVISOR`.

| **voyage_id** | imo | exit_port | destination_port | follow_country | eta | supervisor |
|---|---|---|---|---|---|---|
| 1 | 8841917 | KHATANGA | BETHEL | CAN | 1695319505000 | Sidorov Ivan Ivanovich |
| 2 | 9841931 | TORONTO | OSLO | NOR | 1695319605000 | Anna Maria Johnson |
| 3 | 8841920 | VALDEZ | FALMOUTH | AUS | 1695318605000 | John Doe Smith |
| 4 | 9841932 | HAMBURG | GDANSK | POL | 1695318626000 | Lars Müller |
| 5 | 9841933 | GENOA | BARCELONA | ESP | 1697911505000 | Giuseppe Verdi |
| 6 | 9841934 | MURMANSK | STOCKHOLM | SWE | 1697911505000 | Alexei Ivanov |
| 7 | 9841935 | SYDNEY | WELLINGTON | NZ | 1697911505000 | Emily Johnson |

### Таблица `PORT` (3НФ)

Ключ: **port_name**.

| **port_name** | country |
|---|---|
| KHATANGA | USA |
| BETHEL | USA |
| TORONTO | CAN |
| OSLO | NOR |
| VALDEZ | USA |
| FALMOUTH | UK |
| HAMBURG | GER |
| GDANSK | POL |
| GENOA | ITA |
| BARCELONA | ESP |
| MURMANSK | RUS |
| STOCKHOLM | SWE |
| SYDNEY | AUS |
| WELLINGTON | NZ |

### Таблица `SUPERVISOR` (3НФ)

Ключ: **full_name**.

| **full_name** | company |
|---|---|
| Sidorov Ivan Ivanovich | ShipVising inc. |
| Anna Maria Johnson | AtlanticKeeper Inc. |
| John Doe Smith | OceanGuardian Ltd. |
| Lars Müller | BalticShipping Ltd. |
| Giuseppe Verdi | MediterraneanCruises Inc. |
| Alexei Ivanov | PolarResearch Corp. |
| Emily Johnson | AustralisShipping Ltd. |

### Таблица `SEA_AREA` (3НФ)

Ключ: **sea**.

| **sea** | area_km |
|---|---|
| Barents Sea | 1424000 |
| Atlantic Ocean | 1120000 |
| North Sea | 1300000 |
| Baltic Sea | 1030000 |
| Mediterranean Sea | 1100500 |
| Tasman Sea | 930000 |

### Таблица `SEA_TYPE` (3НФ)

Ключ: **(sea, sea_type)**. Внешний ключ: `sea → SEA_AREA`. Данные как в 1НФ (12 строк).

### Таблица `REPORT` (3НФ)

Ключ: **(voyage_id, receive_date)**. Внешние ключи: `voyage_id → VOYAGE`, `sea → SEA_AREA`.

| **voyage_id** | **receive_date** | source | sea | nav_status | latitude | longitude | course | speed | rot | heading |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2023-09-09 17:07:28 | EXACTEARTH | Barents Sea | At Anchor | 60.76969 | -161.75143 | 282.6 | 0.0 | 0.0 | 9 |
| 2 | 2023-09-09 19:00:00 | SHIPFINDER | Atlantic Ocean | Moored | 52.46592 | -142.69320 | 272.8 | 4 | 2 | 18 |
| 3 | 2023-09-09 18:00:00 | OCEANTRACKER | North Sea | Underway using engine | 54.76960 | -152.75130 | 280.1 | 3 | 1 | 12 |
| 3 | 2023-09-09 20:00:00 | OCEANTRACKER | North Sea | Underway using engine | 54.77960 | -152.77130 | 280.1 | 3 | 1 | 12 |
| 4 | 2023-09-09 20:00:00 | SHIPFINDER | Baltic Sea | Underway using engine | 53.50192 | -141.69320 | 270.0 | -12 | 0 | 272 |
| 4 | 2023-09-09 22:13:00 | SHIPFINDER | Baltic Sea | Underway using engine | 53.51192 | -141.70120 | 270.0 | -12 | 0 | 272 |
| 5 | 2023-09-09 21:00:00 | EXACTEARTH | Mediterranean Sea | Underway using engine | 43.80171 | 7.69320 | 88.0 | 14 | 0 | 90 |
| 6 | 2023-09-09 22:00:00 | EXACTEARTH | Barents Sea | Underway using engine | 68.96192 | 33.09320 | 330.0 | 16 | 0 | 334 |
| 7 | 2023-09-09 23:00:00 | OCEANTRACKER | Tasman Sea | Underway using engine | -33.86985 | 151.20930 | 150.0 | 18 | 0 | 152 |
| 7 | 2023-09-09 23:15:13 | OCEANTRACKER | Tasman Sea | Underway using engine | -33.85985 | 151.21930 | 150.0 | 18 | 0 | 152 |

**Что осталось:** формально 3НФ достигнута, но нужно проверить таблицы на более строгое условие (НФБК), а также решить вопрос с неуникальными именами (порт, оператор) и дублированием текстовых значений (`source`, `nav_status`, `ship_type_name`, коды стран).

---

## 4. Нормальная форма Бойса — Кодда (НФБК)

**Требование:** для каждой нетривиальной ФЗ `X → Y` в таблице `X` является суперключом (то есть любой детерминант — потенциальный ключ).

### 4.1. Проверка каждой таблицы из 3НФ

| Таблица | Потенциальные ключи | Все ФЗ (детерминанты) | Вывод |
|---|---|---|---|
| `SHIP` | `imo`, `mmsi`, `call_sign` | imo → всё; mmsi → всё; call_sign → всё. Других детерминантов нет | Каждый детерминант — потенциальный ключ. **НФБК выполняется** |
| `VOYAGE` | `voyage_id` | voyage_id → всё. Других детерминантов нет | **НФБК выполняется** |
| `REPORT` | `(voyage_id, receive_date)` | (voyage_id, receive_date) → всё | **НФБК выполняется** |
| `PORT` | `port_name` | port_name → country | **НФБК выполняется** |
| `SUPERVISOR` | `full_name` | full_name → company | **НФБК выполняется** |
| `SEA_AREA` | `sea` | sea → area_km | **НФБК выполняется** (см. примечание) |
| `SEA_TYPE` | `(sea, sea_type)` | Нетривиальных ФЗ нет (все атрибуты входят в ключ) | **НФБК выполняется** |

**Особенности проверки:**

- `SHIP` — ключевая таблица для НФБК. У неё три потенциальных ключа, значит, зависимости `mmsi → call_sign` и `call_sign → mmsi` допустимы: слева суперключ. Если бы один из этих идентификаторов не был потенциальным ключом (был бы не уникален), таблица осталась бы в 3НФ, но нарушала бы НФБК.
- `SEA_AREA`: в тестовых данных значения `area_km` попарно различны, поэтому формально выполняется и `area_km → sea`. Это совпадение выборки, а не правило предметной области. Даже если считать эту зависимость настоящей, `area_km` стал бы ещё одним потенциальным ключом, и НФБК не нарушилась бы.
- Составных пересекающихся ключей, на которых обычно ломается НФБК, в схеме нет, поэтому НФБК совпала с 3НФ. Это нормальный результат, а не пропуск шага.

### 4.2. Физический дизайн итоговой схемы (не требуется НФБК, но принято)

Эти изменения не меняют ФЗ и нужны для надёжности и размера данных:

1. **Суррогатные ключи для `PORT` и `SUPERVISOR`.** Допущение «название порта уникально» ложно в реальности (Sydney есть в Австралии и в Канаде), как и «ФИО уникально». Суррогатный ключ `port_id` / `supervisor_id` плюс уникальность `(name, country_id)` и `(company_id, full_name)` сохраняют НФБК, так как ключи остаются потенциальными.
2. **Справочник `COUNTRY`.** Коды стран в данных повторяются в `SHIP` (flag, owner), `PORT` и `VOYAGE` (follow_country). Они нестандартны (`UK`, `GER`, `NZ`), и справочник позволит исправить их в одном месте.
3. **Справочники `COMPANY`, `SHIP_TYPE`, `NAV_STATUS`, `DATA_SOURCE`, `SEA_PURPOSE`.** Вместо повторяющихся текстов в строках таблиц (`Underway using engine` встречается 7 раз) хранится число-ссылка. Опечатка не создаст «новый» статус.
4. **`SEA_TYPE` разбивается на справочник `SEA_PURPOSE` и связь `SEA_AREA_PURPOSE` (M:N).** Сама пара «море — назначение» остаётся ключом.
5. **`SEA_AREA` получает суррогатный `sea_id`**, так как название — атрибут, а не идентификатор.
6. **`REPORT` получает суррогатный `report_id`.** Составной ключ `(voyage_id, receive_date)` остаётся как `UNIQUE`. Это нужно, потому что таблица самая большая и будет расти.

### 4.3. Итоговые таблицы (НФБК)

#### `COUNTRY`: PK `country_id`, UNIQUE `code`

| **country_id** | code |
|---|---|
| 1 | USA |
| 2 | CAN |
| 3 | NOR |
| 4 | UK |
| 5 | AUS |
| 6 | GER |
| 7 | POL |
| 8 | ITA |
| 9 | ESP |
| 10 | RUS |
| 11 | SWE |
| 12 | NZ |

#### `PORT`: PK `port_id`, FK `country_id → COUNTRY`, UNIQUE `(name, country_id)`

| **port_id** | name | country_id |
|---|---|---|
| 1 | KHATANGA | 1 |
| 2 | BETHEL | 1 |
| 3 | TORONTO | 2 |
| 4 | OSLO | 3 |
| 5 | VALDEZ | 1 |
| 6 | FALMOUTH | 4 |
| 7 | HAMBURG | 6 |
| 8 | GDANSK | 7 |
| 9 | GENOA | 8 |
| 10 | BARCELONA | 9 |
| 11 | MURMANSK | 10 |
| 12 | STOCKHOLM | 11 |
| 13 | SYDNEY | 5 |
| 14 | WELLINGTON | 12 |

#### `COMPANY`: PK `company_id`, UNIQUE `name`

| **company_id** | name |
|---|---|
| 1 | ShipVising inc. |
| 2 | AtlanticKeeper Inc. |
| 3 | OceanGuardian Ltd. |
| 4 | BalticShipping Ltd. |
| 5 | MediterraneanCruises Inc. |
| 6 | PolarResearch Corp. |
| 7 | AustralisShipping Ltd. |

#### `SUPERVISOR`: PK `supervisor_id`, FK `company_id → COMPANY`, UNIQUE `(company_id, full_name)`

| **supervisor_id** | full_name | company_id |
|---|---|---|
| 1 | Sidorov Ivan Ivanovich | 1 |
| 2 | Anna Maria Johnson | 2 |
| 3 | John Doe Smith | 3 |
| 4 | Lars Müller | 4 |
| 5 | Giuseppe Verdi | 5 |
| 6 | Alexei Ivanov | 6 |
| 7 | Emily Johnson | 7 |

#### `SHIP_TYPE`: PK `ship_type_id`, UNIQUE `name`

| **ship_type_id** | name |
|---|---|
| 1 | Tanker |
| 2 | Cruise |
| 3 | Cargo |
| 4 | Container Ship |
| 5 | Research Vessel |

#### `NAV_STATUS`: PK `nav_status_id`, UNIQUE `name`

| **nav_status_id** | name |
|---|---|
| 1 | At Anchor |
| 2 | Moored |
| 3 | Underway using engine |

#### `DATA_SOURCE`: PK `source_id`, UNIQUE `name`

| **source_id** | name |
|---|---|
| 1 | EXACTEARTH |
| 2 | SHIPFINDER |
| 3 | OCEANTRACKER |

#### `SEA_AREA`: PK `sea_id`, UNIQUE `name`

| **sea_id** | name | area_km |
|---|---|---|
| 1 | Barents Sea | 1424000 |
| 2 | Atlantic Ocean | 1120000 |
| 3 | North Sea | 1300000 |
| 4 | Baltic Sea | 1030000 |
| 5 | Mediterranean Sea | 1100500 |
| 6 | Tasman Sea | 930000 |

#### `SEA_PURPOSE`: PK `purpose_id`, UNIQUE `name`

| **purpose_id** | name |
|---|---|
| 1 | military |
| 2 | trade |
| 3 | commercial |
| 4 | tourism |
| 5 | research |
| 6 | cruise |

#### `SEA_AREA_PURPOSE`: PK `(sea_id, purpose_id)`, FK `sea_id → SEA_AREA`, FK `purpose_id → SEA_PURPOSE`

| **sea_id** | **purpose_id** |
|---|---|
| 1 | 1 |
| 1 | 2 |
| 2 | 3 |
| 2 | 4 |
| 3 | 5 |
| 3 | 2 |
| 4 | 3 |
| 4 | 2 |
| 5 | 4 |
| 5 | 6 |
| 6 | 3 |
| 6 | 2 |

#### `SHIP`: PK `imo`, UNIQUE `mmsi`, UNIQUE `call_sign`, FK `flag_country_id`, `owner_country_id → COUNTRY`, FK `ship_type_id → SHIP_TYPE`

| **imo** | mmsi | call_sign | name | name_lat | flag_country_id | owner_country_id | ship_type_id |
|---|---|---|---|---|---|---|---|
| 8841917 | 368346000 | WDJ5676 | SADIE | SADIE | 1 | 1 | 1 |
| 9841931 | 377346200 | KLD4921 | ADVENTURER | ADVENTURER | 2 | 2 | 2 |
| 8841920 | 368346010 | WDJ5679 | CORAL | CORAL | 4 | 4 | 3 |
| 9841932 | 377346201 | KLD4922 | BALTIC PIONEER | BALTIC PIONEER | 6 | 6 | 4 |
| 9841933 | 377346202 | KLD4923 | OCEAN TRAVELLER | OCEAN TRAVELLER | 8 | 8 | 2 |
| 9841934 | 377346203 | KLD4924 | ARCTIC EXPLORER | ARCTIC EXPLORER | 10 | 10 | 5 |
| 9841935 | 377346204 | KLD4925 | SOUTHERN STAR | SOUTHERN STAR | 5 | 5 | 3 |

#### `VOYAGE`: PK `voyage_id`, FK `imo → SHIP`, FK `exit_port_id`, `destination_port_id → PORT`, FK `follow_country_id → COUNTRY`, FK `supervisor_id → SUPERVISOR`

| **voyage_id** | imo | exit_port_id | destination_port_id | follow_country_id | eta (мс) | supervisor_id |
|---|---|---|---|---|---|---|
| 1 | 8841917 | 1 | 2 | 2 | 1695319505000 | 1 |
| 2 | 9841931 | 3 | 4 | 3 | 1695319605000 | 2 |
| 3 | 8841920 | 5 | 6 | 5 | 1695318605000 | 3 |
| 4 | 9841932 | 7 | 8 | 7 | 1695318626000 | 4 |
| 5 | 9841933 | 9 | 10 | 9 | 1697911505000 | 5 |
| 6 | 9841934 | 11 | 12 | 11 | 1697911505000 | 6 |
| 7 | 9841935 | 13 | 14 | 12 | 1697911505000 | 7 |

#### `POSITION_REPORT`: PK `report_id`, UNIQUE `(voyage_id, received_at)`, FK `voyage_id → VOYAGE`, FK `source_id → DATA_SOURCE`, FK `sea_id → SEA_AREA`, FK `nav_status_id → NAV_STATUS`

| **report_id** | voyage_id | received_at | source_id | sea_id | nav_status_id | latitude | longitude | course | speed | rot | heading |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 2023-09-09 17:07:28 | 1 | 1 | 1 | 60.76969 | -161.75143 | 282.6 | 0.0 | 0.0 | 9 |
| 2 | 2 | 2023-09-09 19:00:00 | 2 | 2 | 2 | 52.46592 | -142.69320 | 272.8 | 4 | 2 | 18 |
| 3 | 3 | 2023-09-09 18:00:00 | 3 | 3 | 3 | 54.76960 | -152.75130 | 280.1 | 3 | 1 | 12 |
| 4 | 4 | 2023-09-09 20:00:00 | 2 | 4 | 3 | 53.50192 | -141.69320 | 270.0 | -12 | 0 | 272 |
| 5 | 5 | 2023-09-09 21:00:00 | 1 | 5 | 3 | 43.80171 | 7.69320 | 88.0 | 14 | 0 | 90 |
| 6 | 6 | 2023-09-09 22:00:00 | 1 | 1 | 3 | 68.96192 | 33.09320 | 330.0 | 16 | 0 | 334 |
| 7 | 7 | 2023-09-09 23:00:00 | 3 | 6 | 3 | -33.86985 | 151.20930 | 150.0 | 18 | 0 | 152 |
| 8 | 3 | 2023-09-09 20:00:00 | 3 | 3 | 3 | 54.77960 | -152.77130 | 280.1 | 3 | 1 | 12 |
| 9 | 4 | 2023-09-09 22:13:00 | 2 | 4 | 3 | 53.51192 | -141.70120 | 270.0 | -12 | 0 | 272 |
| 10 | 7 | 2023-09-09 23:15:13 | 3 | 6 | 3 | -33.85985 | 151.21930 | 150.0 | 18 | 0 | 152 |

### 4.4. Повторная проверка НФБК для итоговых таблиц

| Таблица | Потенциальные ключи | Детерминанты | Вердикт |
|---|---|---|---|
| `COUNTRY` | `country_id`, `code` | country_id → code; code → country_id | НФБК |
| `PORT` | `port_id`, `(name, country_id)` | port_id → name, country_id; (name, country_id) → port_id | НФБК |
| `COMPANY` | `company_id`, `name` | оба взаимно определяют друг друга | НФБК |
| `SUPERVISOR` | `supervisor_id`, `(company_id, full_name)` | оба — потенциальные ключи | НФБК |
| `SHIP_TYPE`, `NAV_STATUS`, `DATA_SOURCE`, `SEA_PURPOSE` | `id`, `name` | id ↔ name | НФБК |
| `SEA_AREA` | `sea_id`, `name` | sea_id → name, area_km; name → sea_id, area_km | НФБК |
| `SEA_AREA_PURPOSE` | `(sea_id, purpose_id)` | нет нетривиальных ФЗ | НФБК |
| `SHIP` | `imo`, `mmsi`, `call_sign` | каждый определяет остальные | НФБК |
| `VOYAGE` | `voyage_id` | voyage_id → всё | НФБК |
| `POSITION_REPORT` | `report_id`, `(voyage_id, received_at)` | оба определяют все остальные атрибуты | НФБК |

---

## 5. Сводка по шагам

| Шаг | Что нарушалось | Что сделано | Итог |
|---|---|---|---|
| 0НФ → 1НФ | `seaTypes` — список в ячейке, нет ключа | Список вынесен в `SEA_TYPE`, ключ `(imo, receive_date)` | 2 таблицы |
| 1НФ → 2НФ | Атрибуты судна и рейса зависят от части ключа | Выделены `SHIP`, `VOYAGE`, в `REPORT` ключ `(voyage_id, receive_date)` | 4 таблицы |
| 2НФ → 3НФ | Транзитивные: порт → страна, оператор → компания, море → площадь | Выделены `PORT`, `SUPERVISOR`, `SEA_AREA` | 7 таблиц |
| 3НФ → НФБК | Все детерминанты уже являются ключами. Проверены все таблицы. Введены суррогатные ключи и справочники для надёжности | `COUNTRY`, `COMPANY`, `SHIP_TYPE`, `NAV_STATUS`, `DATA_SOURCE`, `SEA_PURPOSE`, `SEA_AREA_PURPOSE` | 13 таблиц |

## 6. Замечания по данным (пригодятся для загрузчика и проверок)

- Файл `ships_data.json` невалиден как JSON: в первой записи есть комментарии `-- ...`. Перед `json.load` их нужно вырезать.
- Ключ `"сountry"` в JSON написан с **кириллической «с»**.
- `seaTypes` — строка с Python-списком, разбирать через `ast.literal_eval`. Порядок значений разный (`['trade','military']` и `['military','trade']`), при этом набор для одного моря одинаков.
- `seaAreaKm` — строка, приводить к числу. `eta` — миллисекунды, приводить к `timestamptz`.
- Порт `KHATANGA` указан в стране USA (на самом деле это Россия). Для лабы это тестовые данные, но такие места подходят для проверок ограничений.
- SADIE в Barents Sea на долготе −161° и ADVENTURER с `speed = 4` при статусе `Moored` — примеры «непротиворечивости», которые стоит учесть при написании `CHECK`.
- Отрицательная скорость `-12` у BALTIC PIONEER нарушает здравый смысл, на неё стоит поставить ограничение (или явно решить, что это допустимо).
- Допущения F4 и F5 (название порта и ФИО оператора определяют страну и компанию) верны только на тестовой выборке. Именно поэтому в итоговой схеме порт и оператор получили суррогатные ключи.
