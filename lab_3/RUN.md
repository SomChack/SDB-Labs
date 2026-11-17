# Лабораторная работа №3: запуск скриптов

Индексы и планы запросов, статистика индексов (pgstattuple), полнотекстовый поиск (tsvector + GIN),
материализованное представление, Data Object View (INSTEAD OF-триггеры). Отчёт: `Отчёт Лабораторная №3.docx`.

## Запуск
```bash
docker compose up -d                      # схема создаётся из init.sql
pip install -r requirements.txt
python load_data.py                       # port_data.csv, ship_data.csv, sea_zones.json из lab_2/module_2
# выполнять по порядку в DBeaver/psql:
#   01_indexes_and_plans.sql, 02_index_statistics.sql, 03_create_disp_messages.sql
python load_messages.py                   # messages.csv -> disp_messages
#   04_fulltext_search.sql, 05_dov.sql
```
