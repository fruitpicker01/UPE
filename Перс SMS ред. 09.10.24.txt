import re
import gradio as gr
import os
import pandas as pd
import time
from langchain.schema import SystemMessage
from langchain_community.chat_models.gigachat import GigaChat
from openpyxl import load_workbook
import plotly.graph_objects as go
import random
import pymorphy2
import string
import json
from mistralai import Mistral
from collections import defaultdict
import requests
import base64
import io

#MISTRAL_API_KEY = os.getenv('MISTRAL_API_KEY')
token = os.getenv('GITHUB_TOKEN')

# Клиент для генерации сообщений
#client_mistral_generate = Mistral(api_key=MISTRAL_API_KEY)

# Клиент для выполнения проверок
#client_mistral_check = Mistral(api_key=MISTRAL_API_KEY)

morph = pymorphy2.MorphAnalyzer()

# Авторизация в GigaChat Pro
gc_key = os.getenv('GC_KEY')
#chat_pro = GigaChat(credentials=gc_key, model='GigaChat', max_tokens=68, temperature=1.15, verify_ssl_certs=False)
chat_pro = GigaChat(
    credentials=gc_key,
    model='GigaChat-Pro-preview',
    base_url='https://gigachat-preview.devices.sberbank.ru/api/v1/',
    max_tokens=68,
    temperature=1.15,
    verify_ssl_certs=False
)

chat_pro_check = GigaChat(
    credentials=gc_key,
    model='GigaChat-Pro-preview',
    base_url='https://gigachat-preview.devices.sberbank.ru/api/v1/',
    max_tokens=3000,
    temperature=0.8,
    verify_ssl_certs=False
)

approach_stats = {
    "Начни сообщение с призыва к действию с продуктом.": {"failed_checks": defaultdict(int), "total_attempts": 0},
    "Начни сообщение с указания на пользу продукта. Используй глагол в побудительном наклонении.": {"failed_checks": defaultdict(int), "total_attempts": 0},
    "Начни сообщение с вопроса, который указывает на пользу продукта для клиента.": {"failed_checks": defaultdict(int), "total_attempts": 0}
}

# Загрузка данных из Excel-файла
try:
    data = pd.read_excel('Признаки.xlsx', sheet_name=None)
except Exception as e:
    print(f"Ошибка при загрузке Excel-файла: {e}")
    data = {}

# Создание списка признаков и их значений
features = {}
for sheet_name, df in data.items():
    try:
        if sheet_name == "Пол Поколение Психотип":
            features[sheet_name] = df.set_index(['Пол', 'Поколение', 'Психотип'])['Инструкция'].to_dict()
        else:
            features[sheet_name] = df.set_index(df.columns[0]).to_dict()[df.columns[1]]
    except Exception as e:
        print(f"Ошибка при обработке данных листа {sheet_name}: {e}")
        features[sheet_name] = {}

# Функция для создания спидометра
def create_gauge(value):
    fig = go.Figure(go.Indicator(
        mode="gauge+number",
        value=value,
        gauge={
            'axis': {'range': [0, 100]},
            'bar': {'color': "black"},  # Цвет стрелки
            'steps': [
                {'range': [0, 40], 'color': "#55efc4"},  # Мягкий зеленый
                {'range': [40, 70], 'color': "#ffeaa7"},  # Желтый
                {'range': [70, 100], 'color': "#ff7675"}  # Мягкий красный
            ],
            'threshold': {
                'line': {'color': "black", 'width': 4},
                'thickness': 0.75,
                'value': value
            }
        },
        number={'font': {'size': 48}}  # Размер шрифта числа
    ))
    fig.update_layout(paper_bgcolor="#f8f9fa", font={'color': "#2d3436", 'family': "Arial"}, width=250, height=150)
    return fig

def save_statistics_to_github(approach_stats):
    repo = "fruitpicker01/Storage_dev"
    timestamp = int(time.time())
    json_path = f"check_{timestamp}.json"
    csv_path = "checks.csv"
    url_json = f"https://api.github.com/repos/{repo}/contents/{json_path}"
    url_csv = f"https://api.github.com/repos/{repo}/contents/{csv_path}"
    headers = {
        "Authorization": f"token {token}",
        "Content-Type": "application/json"
    }
    
    # Подготовка данных для JSON
    json_data = {
        "timestamp": timestamp,
        "approach_stats": approach_stats
    }
    json_content = json.dumps(json_data, ensure_ascii=False, indent=4)
    json_content_encoded = base64.b64encode(json_content.encode('utf-8')).decode('utf-8')
    data_json = {
        "message": f"Добавлен новый файл {json_path}",
        "content": json_content_encoded
    }
    # Сохранение JSON-файла
    response = requests.put(url_json, headers=headers, data=json.dumps(data_json))
    if response.status_code in [200, 201]:
        print("JSON-файл успешно сохранен на GitHub")
    else:
        print(f"Ошибка при сохранении JSON-файла: {response.status_code} {response.text}")
    
    # Подготовка данных для CSV
    import pandas as pd
    rows = []
    for approach, stats in approach_stats.items():
        for check_name, count in stats["failed_checks"].items():
            rows.append({
                "Timestamp": timestamp,
                "Approach": approach,
                "Check": check_name,
                "Failed_Count": count,
                "Total_Attempts": stats["total_attempts"]
            })
    df = pd.DataFrame(rows)
    
    # Проверяем, существует ли уже файл CSV
    response = requests.get(url_csv, headers=headers)
    if response.status_code == 200:
        # Файл существует, загружаем и добавляем данные
        content = response.json()
        csv_content = base64.b64decode(content['content']).decode('utf-8')
        existing_df = pd.read_csv(io.StringIO(csv_content))
        df = pd.concat([existing_df, df], ignore_index=True)
        sha = content['sha']
    else:
        # Файл не существует
        sha = None
    
    csv_content = df.to_csv(index=False)
    csv_content_encoded = base64.b64encode(csv_content.encode('utf-8')).decode('utf-8')
    data_csv = {
        "message": "Обновление файла checks.csv",
        "content": csv_content_encoded
    }
    if sha:
        data_csv["sha"] = sha
    # Сохранение CSV-файла
    response = requests.put(url_csv, headers=headers, data=json.dumps(data_csv))
    if response.status_code in [200, 201]:
        print("CSV-файл успешно сохранен на GitHub")
    else:
        print(f"Ошибка при сохранении CSV-файла: {response.status_code} {response.text}")

# Функция для генерации случайных значений спидометров
def generate_random_gauges():
    return create_gauge(random.randint(80, 95)), create_gauge(random.randint(80, 95)), create_gauge(random.randint(80, 95))

# Функция для смены вкладки
def change_tab(id):
    return gr.Tabs(selected=id)

# Вспомогательная функция для добавления префиксов и суффиксов
def add_prefix_suffix(prompt, prefix, suffix):
    return f"{prefix}\n{prompt}\n{suffix}"

# Функция для обрезки сообщения до последнего знака препинания
def clean_message(message):
    if not message.endswith(('.', '!', '?')):
        last_period = max(message.rfind('.'), message.rfind('!'), message.rfind('?'))
        if last_period != -1:
            message = message[:last_period + 1]
    return message

# Функция для генерации сообщения с GigaChat Pro
def generate_message_gigachat_pro(prompt):
    try:
        messages = [SystemMessage(content=prompt)]
        res = chat_pro(messages)
        cleaned_message = clean_message(res.content.strip())
        return cleaned_message
    except Exception as e:
        return f"Ошибка при обращении к GigaChat-Pro: {e}"

#def generate_message_mistral_generate(prompt, max_retries=5):
#    retries = 0
#    while retries < max_retries:
#        try:
#            chat_response = client_mistral_generate.chat.complete(
#                model="mistral-large-latest",
#                messages=[
#                    {
#                        "role": "user",
#                        "content": prompt,
#                        "max_tokens": 68,
#                        "temperature": 0.8
#                    },
#                ]
#            )
#            cleaned_message = clean_message(chat_response.choices[0].message.content.strip())
#            return cleaned_message
#        except Exception as e:
#                if "Status 429" in str(e):
#                    wait_time = 3  # Можно установить фиксированную задержку
#                    print(f"Превышен лимит запросов. Ожидание {wait_time} секунд перед повторной попыткой...")
#                    time.sleep(wait_time)
#                    retries += 1
#                else:
#                    print(f"Ошибка при обращении к Mistral: {e}")
#                    return None

#def generate_message_mistral_check(prompt, max_retries=5):
#    retries = 0
#    while retries < max_retries:
#        try:
#            chat_response = client_mistral_check.chat.complete(
#                model="mistral-large-latest",
#                messages=[
#                    {
#                        "role": "user",
#                        "content": prompt,
#                        "max_tokens": 3000,
#                        "temperature": 0.2
#                    },
#                ]
#            )
#            cleaned_message = clean_message(chat_response.choices[0].message.content.strip())
#            return cleaned_message
#        except Exception as e:
#                if "Status 429" in str(e):
#                    wait_time = 3  # Можно установить фиксированную задержку
#                    print(f"Превышен лимит запросов. Ожидание {wait_time} секунд перед повторной попыткой...")
#                    time.sleep(wait_time)
#                    retries += 1
#                else:
#                    print(f"Ошибка при обращении к Mistral: {e}")
#                    return None

def generate_check_gigachat_pro(prompt):
    try:
        messages = [SystemMessage(content=prompt)]
        res2 = chat_pro_check(messages)
        cleaned_message = clean_message(res2.content.strip())
        return cleaned_message
    except Exception as e:
        return f"Ошибка при обращении к GigaChat-Pro: {e}"

# Функция для замены сокращений с 'k' или 'К' на тысячи
def replace_k_with_thousands(message):
    # Замена и для 'k' и для 'К', с учётом регистра
    message = re.sub(r'(\d+)[kкКK]', r'\1 000', message, flags=re.IGNORECASE)
    return message

def correct_dash_usage(text):
    morph = pymorphy2.MorphAnalyzer()
    # Step 1: Replace any dash with long dash if surrounded by spaces
    text = re.sub(r'\s[-–—]\s', ' — ', text)

    # Step 2: Replace any dash with short dash if surrounded by numbers without spaces
    text = re.sub(r'(?<=\d)[-–—](?=\d)', '–', text)

    # Step 3: Replace any dash with hyphen if surrounded by letters or a combination of letters and digits
    text = re.sub(r'(?<=[a-zA-Zа-яА-Я0-9])[-–—](?=[a-zA-Zа-яА-Я0-9])', '-', text)

    # Step 4: Replace quotation marks "..." with «...»
    text = re.sub(r'"([^\"]+)"', r'«\1»', text)

    # Step 5: Remove single quotes
    if text.count('"') == 1:
        text = text.replace('"', '')

    # Step 6: Remove outer quotes if the entire text is enclosed in quotes (straight or elided)
    if (text.startswith('"') and text.endswith('"')) or (text.startswith('«') and text.endswith('»')):
        text = text[1:-1].strip()

    # Step 7: Replace 100k with 100 000
    text = re.sub(r'(\d+)[kкКK]', r'\1 000', text, flags=re.IGNORECASE)

    # Step 8: Remove first sentence if it contains greetings and is less than 5 words
    greeting_patterns = [
        r"привет\b", r"здравствуй", r"добрый\s(день|вечер|утро)",
        r"дорогой\b", r"уважаемый\b", r"дорогая\b", r"уважаемая\b",
        r"господин\b", r"госпожа\b", r"друг\b", r"коллега\b",
        r"товарищ\b", r"приятель\b", r"подруга\b"
    ]
    
    def is_greeting_sentence(sentence):
        words = sentence.split()
        if len(words) < 5:  # Check if sentence is less than 5 words
            for word in words:
                parsed = morph.parse(word.lower())[0]  # Parse the word to get its base form
                for pattern in greeting_patterns:
                    if re.search(pattern, parsed.normal_form):
                        return True
        return False

    # Split text into sentences
    sentences = re.split(r'(?<=[.!?])\s+', text)
    
    # Check the first sentence for greetings and remove it if necessary
    if sentences and is_greeting_sentence(sentences[0]):
        sentences = sentences[1:]

    # Join the sentences back
    text = ' '.join(sentences)

    def restore_yo(text):
        morph = pymorphy2.MorphAnalyzer()
        words = text.split()
        restored_words = []
        
        for word in words:
            # Пропускать обработку, если слово полностью в верхнем регистре (аббревиатуры)
            if word.isupper():
                restored_words.append(word)
                continue
            
            # Пропускать обработку, если слово "все" (независимо от регистра)
            if word.lower() == "все":
                restored_words.append(word)
                continue
            
            # Обработка остальных слов
            parsed = morph.parse(word)[0]
            restored_word = parsed.word
            
            # Сохраняем оригинальный регистр первой буквы
            if word and word[0].isupper():
                restored_word = restored_word.capitalize()
            
            restored_words.append(restored_word)
        
        return ' '.join(restored_words)

    text = restore_yo(text)

    # Step 9: Replace common abbreviations and acronyms (Ип -> ИП, Ооо -> ООО, Рф -> РФ)
    text = re.sub(r'\bИп\b', 'ИП', text, flags=re.IGNORECASE)
    text = re.sub(r'\bОоо\b', 'ООО', text, flags=re.IGNORECASE)
    text = re.sub(r'\bРф\b', 'РФ', text, flags=re.IGNORECASE)

    # Step 10: Replace specific words (пользуйтесь -> пользуйтесь, ею -> ей)
    text = re.sub(r'\bпользовуйтесь\b', 'пользуйтесь', text, flags=re.IGNORECASE)
    text = re.sub(r'\bею\b', 'ей', text, flags=re.IGNORECASE)
    text = re.sub(r'\bповышьте\b', 'повысьте', text, flags=re.IGNORECASE)

    text = re.sub(r'\bСбербизнес\b', 'СберБизнес', text, flags=re.IGNORECASE)
    text = re.sub(r'\bСбербанк\b', 'СберБанк', text, flags=re.IGNORECASE)
    text = re.sub(r'\bвашего ООО\b', 'вашей компании', text, flags=re.IGNORECASE)

    # Step 11: Replace all forms of "рублей", "рубля", "руб." with "р"
    # Используем два отдельных регулярных выражения для точности
    # 1. Заменяем "руб." на "р", учитывая, что "руб." может быть перед символом "/" или другим несловесным символом
    text = re.sub(r'\bруб\.(?=\W|$)', 'р', text, flags=re.IGNORECASE)
    # 2. Заменяем "рубля" и "рублей" на "р"
    text = re.sub(r'\bруб(?:ля|лей)\b', 'р', text, flags=re.IGNORECASE)

    # Step 12: Replace thousands and millions with appropriate abbreviations
    text = re.sub(r'(\d+)\s+тысяч(?:а|и)?(?:\s+рублей)?', r'\1 000 р', text, flags=re.IGNORECASE)
    text = re.sub(r'(\d+)\s*тыс\.\s*руб\.', r'\1 000 р', text, flags=re.IGNORECASE)
    text = re.sub(r'(\d+)\s*тыс\.\s*р\.', r'\1 000 р', text, flags=re.IGNORECASE)

    # Replace millions with "млн"
    text = re.sub(r'(\d+)\s+миллиона\b|\bмиллионов\b', r'\1 млн', text, flags=re.IGNORECASE)
    text = re.sub(r'(\d+)\s*млн\s*руб\.', r'\1 млн р', text, flags=re.IGNORECASE)

    # Ensure space formatting around currency abbreviations
    text = re.sub(r'(\d+)\s*р\b', r'\1 р', text)

    # Step 13: Remove sentences containing "никаких посещений" or "никаких визитов"
    def remove_specific_sentences(text):
        sentences = re.split(r'(?<=[.!?])\s+', text)  # Разбиваем текст на предложения
        filtered_sentences = [
            sentence for sentence in sentences 
            if not re.search(r'\bникаких\s+(посещений|визитов)\b', sentence, flags=re.IGNORECASE)
        ]
        return ' '.join(filtered_sentences)
        
    # Шаг 14: Замена чисел вида "5 000 000 р" на "5 млн р"
    text = re.sub(r'\b(\d+)\s+000\s+000\s*р\b', r'\1 млн р', text, flags=re.IGNORECASE)

    text = remove_specific_sentences(text)

    return text


# Функция для добавления ошибок в промпт для перегенерации
def append_errors_to_prompt(prompt, checks):
    # Словарь с сообщениями об ошибках для каждого правила
    error_messages = {
        "forbidden_words": "Не использовать запрещённые слова: номер один, №1, № 1, номер, вкусный, дешёвый, продукт, спам, банкротство, долг, займ, срочный, главный, гарантия, успех, лидер.",
        "client_addressing": "Не обращаться к клиенту напрямую.",
        "promises": "Не давать обещания и гарантии.",
        "double_verbs": "Не использовать два глагола подряд (например, 'хочешь оформить').",
        "participles": "Не использовать причастия.",
        "adverbial_participles": "Не использовать деепричастия.",
        "superlative_adjectives": "Не использовать превосходную степень прилагательных.",
        "passive_voice": "Избегать страдательного залога.",
        "written_out_ordinals": "Не использовать порядковые числительные от 10 прописью.",
        "subordinate_clauses_chain": "Избегать цепочек с придаточными предложениями.",
        "repeating_conjunctions": "Не использовать разделительные повторяющиеся союзы.",
        "introductory_phrases": "Не использовать вводные конструкции.",
        "amplifiers": "Не использовать усилители.",
        "time_parasites": "Не использовать 'паразиты времени'.",
        "multiple_nouns": "Избегать нескольких существительных подряд.",
        "derived_prepositions": "Не использовать производные предлоги.",
        "compound_sentences": "Избегать сложноподчиненных предложений.",
        "dates_written_out": "Не писать даты прописью.",
        "no_word_repetitions": "Избегать повторов слов.",
        "disconnected_sentences": "Избегать сложных предложений без логической связи.",
        "synonymous_members": "Не использовать близкие по смыслу однородные члены предложения.",
        "clickbait_phrases": "Не использовать кликбейтные фразы.",
        "abstract_claims": "Избегать абстрактных заявлений без доказательств.",
        "specialized_terms": "Не использовать узкоспециализированные термины.",
        "offensive_phrases": "Избегать двусмысленных или оскорбительных фраз.",
        "cliches_and_bureaucratese": "Не использовать речевые клише, рекламные штампы, канцеляризмы.",
        "no_contradictions": "Избегать противоречий с описанием предложения.",
        "contains_key_message": "Обязательно включить ключевое сообщение."
    }

    # Находим первую не пройденную проверку
    for check_name, passed in checks.items():
        if passed is False:
            error_message = error_messages.get(check_name, f"Ошибка в проверке {check_name}.")
            error_instruction = "Следующую ошибку необходимо избежать:\n" + error_message
            prompt += f"\n\n{error_instruction}"
            break  # Останавливаемся на первой ошибке

    return prompt

    
def notify_failed_length(message_length):
    if message_length < 120:
        gr.Warning(f"Сообщение слишком короткое: {message_length} знаков. Минимум 120.")
        return False
    elif message_length > 250:
        gr.Warning(f"Сообщение слишком длинное: {message_length} знаков. Максимум 250.")
        return False
    return True

# Функция для уведомления о непройденных проверках
def notify_failed_checks(checks):
    translation = {
        "forbidden_words": "Запрещенные слова",
        "client_addressing": "Обращение к клиенту",
        "promises": "Обещания и гарантии",
        "double_verbs": "Два глагола подряд",
        "participles": "Причастия",
        "adverbial_participles": "Деепричастия",
        "superlative_adjectives": "Превосходная степень",
        "passive_voice": "Страдательный залог",
        "written_out_ordinals": "Порядковые числительные",
        "subordinate_clauses_chain": "Цепочки с придаточными предложениями",
        "repeating_conjunctions": "Разделительные повторяющиеся союзы",
        "introductory_phrases": "Вводные конструкции",
        "amplifiers": "Усилители",
        "time_parasites": "Паразиты времени",
        "multiple_nouns": "Несколько существительных подряд",
        "derived_prepositions": "Производные предлоги",
        "compound_sentences": "Сложноподчиненные предложения",
        "dates_written_out": "Даты прописью",
        "no_word_repetitions": "Повторы слов",
        "disconnected_sentences": "Сложные предложения без логической связи",
        "synonymous_members": "Близкие по смыслу однородные члены предложения",
        "clickbait_phrases": "Кликбейтные фразы",
        "abstract_claims": "Абстрактные заявления без доказательств",
        "specialized_terms": "Узкоспециализированные термины",
        "offensive_phrases": "Двусмысленные или оскорбительные фразы",
        "cliches_and_bureaucratese": "Речевые клише, рекламные штампы, канцеляризмы",
        "no_contradictions": "Противоречия с описанием предложения",
        "contains_key_message": "Отсутствие ключевого сообщения"
    }

    # Находим первую не пройденную проверку
    for check_name, passed in checks.items():
        if passed is False:
            failed_check = translation.get(check_name, check_name)
            gr.Warning(f"Сообщение не прошло следующую проверку: {failed_check}")
            break  # Останавливаемся на первой ошибке
    else:
        # Если все проверки пройдены, выводим уведомление
        gr.Warning("ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ")

# Модифицированная функция перегенерации сообщений с уведомлениями о номере попытки
def generate_message_gigachat_pro_with_retry(prompt, current_prefix, description, key_message):
    global approach_stats
    last_message = None
    for attempt in range(30):
        gr.Info(f"Итерация {attempt + 1}: генерируется сообщение...")
        message = generate_message_gigachat_pro(prompt)
        message = replace_k_with_thousands(message)
        message = correct_dash_usage(message)
        message_length = len(message)
        if not notify_failed_length(message_length):
            last_message = message
            time.sleep(1)
            continue
        checks = perform_checks(message, description, key_message)
        last_message = message
        approach_stats[current_prefix]["total_attempts"] += 1
        for check_name, passed in checks.items():
            if passed is False:
                approach_stats[current_prefix]["failed_checks"][check_name] += 1
                break
        notify_failed_checks(checks)  # Вызываем функцию независимо от результата проверок
        if all(checks.values()):
            return message
        prompt = append_errors_to_prompt(prompt, checks)
        time.sleep(1)
    gr.Info("Не удалось сгенерировать сообщение, соответствующее требованиям, за 30 итераций. Возвращаем последнее сгенерированное сообщение.")
    return last_message


#def generate_message_mistral_with_retry(prompt, current_prefix, description, key_message):
#    global approach_stats
#    last_message = None
#    for attempt in range(20):
#        gr.Info(f"Итерация {attempt + 1}: генерируется сообщение...")
#        message = generate_message_mistral_generate(prompt)
#        message = replace_k_with_thousands(message)
#        message = correct_dash_usage(message)
#        message_length = len(message)
#        if not notify_failed_length(message_length):
#            last_message = message
#            time.sleep(1)
#            continue
#        checks = perform_checks(message, description, key_message)
#        last_message = message
#        approach_stats[current_prefix]["total_attempts"] += 1
#        for check_name, passed in checks.items():
#            if passed is False:
#                approach_stats[current_prefix]["failed_checks"][check_name] += 1
#                break
#        notify_failed_checks(checks)  # Вызываем функцию независимо от результата проверок
#        if all(checks.values()):
#            return message
#        prompt = append_errors_to_prompt(prompt, checks)
#        time.sleep(1)
#    gr.Info("Не удалось сгенерировать сообщение, соответствующее требованиям, за 20 итераций. Возвращаем последнее сгенерированное сообщение.")
#    return last_message


# Функция для создания задания для копирайтера
def generate_standard_prompt(description, advantages, key_message, *selected_values):
    prompt = (
        f"Сгенерируй смс-сообщение для клиента.\n"
        f"Описание предложения: {description}\n"
        f"Преимущества: {advantages}\n"
        "В тексте смс запрещено использование:\n"
        "- Запрещенные слова: № один, номер один, № 1, вкусный, дешёвый, продукт, спам, доступный, банкротство, долги, займ, срочно, сейчас, лучший, главный, номер 1, гарантия, успех, лидер, никакой;\n"
        "- Обращение к клиенту;\n"
        "- Приветствие клиента;\n"
        "- Обещания и гарантии;\n"
        "- Использовать составные конструкции из двух глаголов;\n"
        "- Причастия и причастные обороты;\n"
        "- Деепричастия и деепричастные обороты;\n"
        "- Превосходная степень прилагательных;\n"
        "- Страдательный залог;\n"
        "- Порядковые числительные от 10 прописью;\n"
        "- Цепочки с придаточными предложениями;\n"
        "- Разделительные повторяющиеся союзы;\n"
        "- Вводные конструкции;\n"
        "- Усилители;\n"
        "- Паразиты времени;\n"
        "- Несколько существительных подряд, в том числе отглагольных;\n"
        "- Производные предлоги;\n"
        "- Сложные предложения, в которых нет связи между частями;\n"
        "- Сложноподчинённые предложения;\n"
        "- Даты прописью;\n"
        "- Близкие по смыслу однородные члены предложения;\n"
        "- Шокирующие, экстравагантные, кликбейтные фразы;\n"
        "- Абстрактные заявления без поддержки фактами и отсутствие доказательства пользы для клиента;\n"
        "- Гарантирующие фразы;\n"
        "- Узкоспециализированные термины;\n"
        "- Фразы, способные создать двойственное ощущение, обидеть;\n"
        "- Речевые клише, рекламные штампы, канцеляризмы;\n"
        "Убедись, что в готовом тексте до 250, но не менее 120 знаков с пробелами.\n"
    )        
    if key_message.strip():
        prompt += f"Убедись, что в готовом тексте есть следующая ключевая информация: {key_message.strip()}"
     
    return prompt


# Функция для создания задания для редактора с добавлением prefix и suffix
def generate_personalization_prompt(key_message, *selected_values, prefix, suffix):
    prompt = "Адаптируй, не превышая длину сообщения в 250 знаков с пробелами (но и не менее 120 знаков с пробелами), текст с учетом следующих особенностей:\n"
    gender, generation, psychotype = selected_values[0], selected_values[1], selected_values[2]
    combined_instruction = ""
    additional_instructions = ""

    # Проверяем, выбраны ли все три параметра: Пол, Поколение, Психотип
    if gender and generation and psychotype:
        # Получаем данные с листа "Пол Поколение Психотип"
        sheet = features.get("Пол Поколение Психотип", {})

        # Ищем ключ, соответствующий комбинации "Пол", "Поколение", "Психотип"
        key = (gender, generation, psychotype)
        if key in sheet:
            combined_instruction = sheet[key]

    # Если не найдена комбинированная инструкция, добавляем индивидуальные инструкции
    if not combined_instruction:
        for i, feature in enumerate(["Пол", "Поколение", "Психотип"]):
            if selected_values[i]:
                try:
                    instruction = features[feature][selected_values[i]]
                    additional_instructions += f"{instruction}\n"
                except KeyError:
                    return f"Ошибка: выбранное значение {selected_values[i]} не найдено в данных."

    # Добавляем инструкции для остальных параметров (например, Отрасль)
    for i, feature in enumerate(features.keys()):
        if feature not in ["Пол", "Поколение", "Психотип", "Пол Поколение Психотип"]:
            if i < len(selected_values) and selected_values[i]:
                try:
                    instruction = features[feature][selected_values[i]]
                    additional_instructions += f"{instruction}\n"
                except KeyError:
                    return f"Ошибка: выбранное значение {selected_values[i]} не найдено в данных."

    # Формируем итоговый промпт
    if combined_instruction:
        prompt += combined_instruction  # Добавляем комбинированную инструкцию, если она есть
    if additional_instructions:
        prompt += additional_instructions  # Добавляем остальные инструкции

    # Добавляем префикс и суффикс для задания редактора
    prompt = f"{prefix}\n{prompt}\n{suffix}"
    prompt += "Убедись, что в готовом тексте не изменено название предлагаемого продукта.\n"
    
    # Добавляем ключевое сообщение
    prompt += f"\nУбедись, что в готовом тексте есть следующая ключевая информация: {key_message.strip()}"

    return prompt.strip()

# Функция для удаления префиксов, суффиксов и пустых строк перед выводом на экран
def clean_prompt_for_display(prompt, prefixes, suffixes):
    # Удаляем префиксы и суффиксы
    for prefix in prefixes:
        prompt = prompt.replace(prefix, "")
    for suffix in suffixes:
        prompt = prompt.replace(suffix, "")
    
    # Удаляем пустые строки
    lines = prompt.split('\n')
    non_empty_lines = [line for line in lines if line.strip() != '']
    cleaned_prompt = '\n'.join(non_empty_lines)

    return cleaned_prompt.strip()

# Функция для постепенной генерации всех сообщений через yield
def generate_all_messages(desc, benefits, key_message, gender, generation, psychotype, business_stage, industry, opf):
    standard_prompt = generate_standard_prompt(desc, benefits, key_message)
    yield standard_prompt, None, None, None, None, None, None, None
    prefixes = [
        "Начни сообщение с призыва к действию с продуктом.",
        "Начни сообщение с указания на пользу продукта. Используй глагол в побудительном наклонении.",
        "Начни сообщение с вопроса, который указывает на пользу продукта для клиента."
    ]
    suffixes = [
        "Убедись, что готовый текст начинается с призыва к действию с продуктом.",
        "Убедись, что готовый текст начинается с указания на пользу продукта и использования глагола в побудительном наклонении.",
        "Убедись, что готовый текст начинается с вопроса, который указывает на пользу продукта для клиента."
    ]
    non_personalized_messages = []
    personalized_messages = []
    flag = 1
    for i in range(3):
        current_prefix = prefixes[i]
        personalization_prompt = generate_personalization_prompt(
            key_message, gender, generation, psychotype, business_stage, industry, opf,
            prefix=prefixes[i], suffix=suffixes[i]
        )
        display_personalization_prompt = clean_prompt_for_display(personalization_prompt, prefixes, suffixes)
        while flag == 1:
            yield standard_prompt, display_personalization_prompt, None, None, None, None, None, None
            flag += 1
        prompt = add_prefix_suffix(standard_prompt, prefixes[i], suffixes[i])
        non_personalized_message = generate_message_gigachat_pro_with_retry(prompt, current_prefix, desc, key_message)
        non_personalized_length = len(non_personalized_message)
        non_personalized_display = f"{non_personalized_message}\n------\nКоличество знаков: {non_personalized_length}"
        non_personalized_messages.append(non_personalized_display)

        # Выводим неперсонализированное сообщение и задание для редактора
        yield (
            standard_prompt, display_personalization_prompt,  # Задание для редактора без префиксов, суффиксов и пустых строк
            non_personalized_messages[0] if i >= 0 else None,
            personalized_messages[0] if len(personalized_messages) > 0 else None,
            non_personalized_messages[1] if i >= 1 else None,
            personalized_messages[1] if len(personalized_messages) > 1 else None,
            non_personalized_messages[2] if i >= 2 else None,
            personalized_messages[2] if len(personalized_messages) > 2 else None
        )

        # Генерация персонализированного сообщения
        full_personalized_prompt = f"{personalization_prompt}\n\nТекст для адаптации: {non_personalized_message}"
        personalized_message = generate_message_gigachat_pro_with_retry(full_personalized_prompt, current_prefix, desc, key_message)
        personalized_length = len(personalized_message)
        personalized_display = f"{personalized_message}\n------\nКоличество знаков: {personalized_length}"
        personalized_messages.append(personalized_display)

        # Выводим персонализированное сообщение
        yield (
            standard_prompt, display_personalization_prompt,  # Задание для редактора без префиксов, суффиксов и пустых строк
            non_personalized_messages[0] if len(non_personalized_messages) > 0 else None,
            personalized_messages[0] if len(personalized_messages) > 0 else None,
            non_personalized_messages[1] if len(non_personalized_messages) > 1 else None,
            personalized_messages[1] if len(personalized_messages) > 1 else None,
            non_personalized_messages[2] if len(non_personalized_messages) > 2 else None,
            personalized_messages[2] if len(personalized_messages) > 2 else None
        )
        
        time.sleep(1)

    save_statistics_to_github(approach_stats)


# ФУНКЦИИ ПРОВЕРОК (НАЧАЛО)

# 1. Запрещенные слова

def check_forbidden_words(message):   
    morph = pymorphy2.MorphAnalyzer()
    
    # Перечень запрещённых слов и фраз
    forbidden_patterns = [
        r'№\s?1\b', r'номер\sодин\b', r'номер\s1\b',
        r'вкусный', r'дешёвый', r'продукт', 
        r'спам', r'банкротство', r'долг[и]?', r'займ',
        r'срочный', r'главный',
        r'гарантия', r'успех', r'лидер', 'никакой'
    ]
    
    # Удаляем знаки препинания для корректного анализа
    message_without_punctuation = message.translate(str.maketrans('', '', string.punctuation))
    
    # Проверка на наличие подстроки "лучш" (без учета регистра)
    if re.search(r'лучш', message_without_punctuation, re.IGNORECASE):
        return False
    
    # Лемматизация слов сообщения
    words = message_without_punctuation.split()
    lemmas = [morph.parse(word)[0].normal_form for word in words]
    normalized_message = ' '.join(lemmas)

    # Проверка на запрещённые фразы и леммы
    for pattern in forbidden_patterns:
        if re.search(pattern, normalized_message, re.IGNORECASE):
            return False

    return True


# 2 и #3. Обращение к клиенту и приветствие клиента

def check_no_greeting(message):
    morph = pymorphy2.MorphAnalyzer()
    # Список типичных обращений и приветствий
    greeting_patterns = [
        r"привет\b", r"здравствуй", r"добрый\s(день|вечер|утро)",
        r"дорогой\b", r"уважаемый\b", r"дорогая\b", r"уважаемая\b",
        r"господин\b", r"госпожа\b", r"друг\b", r"коллега\b",
        r"товарищ\b", r"приятель\b", r"друг\b", r"подруга\b"
    ]
    
    # Компилируем все шаблоны в один регулярное выражение
    greeting_regex = re.compile('|'.join(greeting_patterns), re.IGNORECASE)
    
    # Проверяем, начинается ли сообщение с шаблона приветствия или обращения
    if greeting_regex.search(message.strip()):
        return False
    return True

# 4. Обещания и гарантии

def check_no_promises(message):
    morph = pymorphy2.MorphAnalyzer()
    promise_patterns = [
        "обещать", "обещание", "гарантировать", "обязаться", "обязать", "обязательство", "обязательный"
    ]
    
    words = message.split()
    lemmas = [morph.parse(word)[0].normal_form for word in words]
    
    for pattern in promise_patterns:
        if pattern in lemmas:
            return False
    return True

# 5. Составные конструкции из двух глаголов

def check_no_double_verbs(message):
    morph = pymorphy2.MorphAnalyzer()
    # Разделяем текст по пробелам и знакам препинания
    words = re.split(r'\s+|[.!?]', message)
    morphs = [morph.parse(word)[0] for word in words]
    
    for i in range(len(morphs) - 1):
        # Проверяем, что оба слова являются глаголами (в любой форме, включая инфинитивы)
        if (morphs[i].tag.POS in {'VERB', 'INFN'}) and (morphs[i+1].tag.POS in {'VERB', 'INFN'}):
            # Проверяем, является ли первый глагол "хотеть" или "начинать"
            if morphs[i].normal_form in ['хотеть', 'начинать', 'начать']:
                return True
            else:
                return False
    return True

# 6. Причастия и причастные обороты

def check_no_participles(message):
    morph = pymorphy2.MorphAnalyzer()
    words = message.split()
    exceptions = {"повышенный", "увеличенный", "пониженный", "сниженный"}
    
    for word in words:
        parsed_word = morph.parse(word)[0]
        lemma = parsed_word.normal_form
        if 'PRTF' in parsed_word.tag and lemma not in exceptions:
            return False
    return True

# 7. Деепричастия и деепричастные обороты

def check_no_adverbial_participles(message):
    morph = pymorphy2.MorphAnalyzer()
    words = message.split()
    morphs = [morph.parse(word)[0] for word in words]
    
    for morph in morphs:
        if 'GRND' in morph.tag:
            return False
    return True

# 8. Превосходная степень прилагательных

def check_no_superlative_adjectives(message):
    morph = pymorphy2.MorphAnalyzer()
    words = message.split()
    morphs = [morph.parse(word)[0] for word in words]
    
    for morph in morphs:
        if 'COMP' in morph.tag or 'Supr' in morph.tag:
            return False
    return True

# 9. Страдательный залог

def check_no_passive_voice(message):
    morph = pymorphy2.MorphAnalyzer()
    words = message.split()
    morphs = [morph.parse(word)[0] for word in words]
    
    for morph in morphs:
        if 'PRTF' in morph.tag and ('passive' in morph.tag or 'в' in morph.tag):
            return False
    return True

# 10. Порядковые числительные от 10 прописью

def check_no_written_out_ordinals(message):
    morph = pymorphy2.MorphAnalyzer()
    ordinal_words = [
        "десятый", "одиннадцатый", "двенадцатый", "тринадцатый", "четырнадцатый", "пятнадцатый",
        "шестнадцатый", "семнадцатый", "восемнадцатый", "девятнадцатый", "двадцатый"
    ]
    
    words = message.split()
    lemmas = [morph.parse(word)[0].normal_form for word in words]
    
    for word in ordinal_words:
        if word in lemmas:
            return False
    return True

# 11. Цепочки с придаточными предложениями

def check_no_subordinate_clauses_chain(message):
    # Регулярное выражение, которое ищет последовательности придаточных предложений
    subordinate_clause_patterns = [
        r'\b(который|которая|которое|которые)\b',
        r'\b(если|потому что|так как|что|когда)\b',
        r'\b(хотя|несмотря на то что)\b'
    ]
    
    count = 0
    for pattern in subordinate_clause_patterns:
        if re.search(pattern, message):
            count += 1
    
    # Если в предложении найдено более одного придаточного предложения подряд, возвращаем False
    return count < 2

# 12. Разделительные повторяющиеся союзы

def check_no_repeating_conjunctions(message):
    # Регулярное выражение для поиска разделительных повторяющихся союзов с запятой перед вторым союзом
    repeating_conjunctions_patterns = r'\b(и|ни|то|не то|или|либо)\b\s*(.*?)\s*,\s*\b\1\b'
    
    # Разделяем сообщение на предложения по точке, вопросительному и восклицательному знакам
    sentences = re.split(r'[.!?]\s*', message)
    
    # Проверяем каждое предложение отдельно
    for sentence in sentences:
        if re.search(repeating_conjunctions_patterns, sentence, re.IGNORECASE):
            return False
    return True

# 13. Вводные конструкции

def check_no_introductory_phrases(message):
    introductory_phrases = [
        r'\b(во-первых|во-вторых|с одной стороны|по сути|по правде говоря)\b',
        r'\b(может быть|кстати|конечно|естественно|безусловно|возможно)\b'
    ]
    
    for pattern in introductory_phrases:
        if re.search(pattern, message, re.IGNORECASE):
            return False
    return True

# 14. Усилители

def check_no_amplifiers(message):
    amplifiers = [
        r'\b(очень|крайне|чрезвычайно|совсем|полностью|чисто)\b'
    ]
    
    for pattern in amplifiers:
        if re.search(pattern, message, re.IGNORECASE):
            return False
    return True

# 15. Паразиты времени

def check_no_time_parasites(message):
    time_parasites = [
        r'\b(немедленно|срочно|в данный момент)\b'
    ]
    
    for pattern in time_parasites:
        if re.search(pattern, message, re.IGNORECASE):
            return False
    return True

# 16. Несколько существительных подряд

def check_no_multiple_nouns(message):
    noun_count = 0
    words = re.split(r'\s+|[.!?]', message)  # Разбиваем по пробелам и знакам препинания
    morph = pymorphy2.MorphAnalyzer()
    
    for word in words:
        parsed_word = morph.parse(word)[0]
        
        # Если слово — существительное
        if 'NOUN' in parsed_word.tag:
            noun_count += 1
        # Если встречен конец предложения (точка, вопросительный знак, восклицательный знак)
        elif re.match(r'[.!?]', word):
            noun_count = 0
        else:
            noun_count = 0
        
        if noun_count > 2:
            return False
    return True

# 17. Производные предлоги

def check_no_derived_prepositions(message):
    derived_prepositions = [
        r'\b(в течение|в ходе|вследствие|в связи с|по мере|при помощи|согласно|вопреки|на основании|на случай|в продолжение|по причине|вблизи|вдалеке|вокруг|внутри|вдоль|посередине|вне|снаружи|благодаря|невзирая на|исходя из)\b'
    ]
    
    for pattern in derived_prepositions:
        if re.search(pattern, message, re.IGNORECASE):
            return False
    return True

# 19. Сложноподчиненные предложения

def check_no_compound_sentences(message):
    subordinating_conjunctions = [
        r'\bкогда\b', r'\bкак только\b', r'\bпока\b', r'\bпосле того как\b',
        r'\bпотому что\b', r'\bтак как\b', r'\bоттого что\b', r'\bблагодаря тому что\b',
        r'\bчтобы\b', r'\bдля того чтобы\b', r'\bесли\b', r'\bкогда бы\b', r'\bесли бы\b',
        r'\bхотя\b', r'\bнесмотря на то что\b', r'\bкак\b', r'\bбудто\b', r'\bсловно\b', r'\bкак будто\b'
    ]
    
    # Убедимся, что слово "как" используется не в вопросе
    for pattern in subordinating_conjunctions:
        if re.search(pattern, message) and not re.search(r'\?', message):
            return False
    return True

# 20. Даты прописью

def check_no_dates_written_out(message):
    # Ищем упоминания месяцев или слов, связанных с датами
    months = [
        "января", "февраля", "марта", "апреля", "мая", "июня", 
        "июля", "августа", "сентября", "октября", "ноября", "декабря"
    ]
    
    # Слова для проверки чисел прописью
    date_written_out_patterns = [
        r'\b(первого|второго|третьего|четвертого|пятого|шестого|седьмого|восьмого|девятого|десятого|одиннадцатого|двенадцатого|тринадцатого|четырнадцатого|пятнадцатого|шестнадцатого|семнадцатого|восемнадцатого|девятнадцатого|двадцатого|двадцать первого|двадцать второго|двадцать третьего|двадцать четвертого|двадцать пятого|двадцать шестого|двадцать седьмого|двадцать восьмого|двадцать девятого|тридцатого|тридцать первого)\b'
    ]
    
    for month in months:
        for pattern in date_written_out_patterns:
            if re.search(f'{pattern}\\s{month}', message, re.IGNORECASE):
                return False
    
    return True

# Доп правило. Повторы слов

def check_no_word_repetitions(message):
    morph = pymorphy2.MorphAnalyzer()
    
    # Список союзов и предлогов, которые мы будем игнорировать
    ignore_words = set([
        'и', 'а', 'но', 'или', 'да', 'ни', 'как', 'так',
        'в', 'на', 'под', 'над', 'за', 'к', 'до', 'по', 'из', 'у', 'о', 'про', 'для',
        'не', 'вот', 'это', 'тот', 'тем', 'при', 'чем',
        'же', 'ли', 'бы', 'то',
    ])
    
    # Разбиваем текст на слова, удаляя знаки препинания
    words = re.findall(r'\b\w+\b', message.lower())
    
    # Словарь для хранения нормализованных форм слов
    normalized_words = {}
    
    for word in words:
        if word not in ignore_words:
            # Получаем нормальную форму слова
            normal_form = morph.parse(word)[0].normal_form
            
            # Если слово уже встречалось, возвращаем False
            if normal_form in normalized_words:
                return False
            
            # Добавляем слово в словарь
            normalized_words[normal_form] = True
    
    # Если мы дошли до этой точки, повторов не было
    return True

# Проверки на LLM

import re
import json

def parse_json_response(response):
    try:
        # Попытка найти JSON-подобную структуру в ответе
        match = re.search(r'\{.*', response)
        if match:
            json_str = match.group(0)
            # Проверяем и добавляем недостающие кавычки и скобки
            if json_str.count('"') % 2 != 0:
                json_str += '"'
            if json_str.count('{') > json_str.count('}'):
                json_str += '}'
            result = json.loads(json_str)
            return result
        
        # Если JSON не найден, пытаемся найти ключ-значение вручную
        else:
            decision_match = re.search(r'decision:\s*(true|false)', response)
            explanation_match = re.search(r'explanation:\s*"(.+?)"', response)
            
            result = {}
            if decision_match:
                decision_value = decision_match.group(1)
                result['decision'] = True if decision_value == 'true' else False
            
            if explanation_match:
                result['explanation'] = explanation_match.group(1)
            
            if result:
                return result
            else:
                print("JSON не найден, и ключи 'decision' и 'explanation' не извлечены")
                return None
    except Exception as e:
        print(f"Ошибка при разборе JSON: {e}")
        return None


def cut_message(message):
    # Удаляем любой дополнительный текст, например, "------\nКоличество знаков: ..."
    # Разделяем сообщение по '------' и берем первую часть
    if '------' in message:
        message = message.split('------')[0].strip()
    return message
        
# 22. Проверка сложных предложений без логической связи
def check_disconnected_sentences(message):
    message_clean = cut_message(message)
    print()
    print("Вторая группа проверок на LLM")
    print()
    print("Проверка 22: Проверка сложных предложений без логической связи")
    print()
    prompt = f'''Проверь следующий текст на наличие сложных предложений, где отсутствует логическая связь между частями:
"{message_clean}"
Определи, есть ли в тексте предложения с несколькими частями, которые кажутся несвязанными, не поддерживают общую мысль или делают текст трудным для понимания.
Обрати внимание, что в контексте коротких рекламных сообщений допустимы краткие предложения, перечисления и фразы, которые вместе передают связную информацию о продукте или услуге. Не считай такие сообщения несвязанными, если их части логически связаны с предложением продукта или условиями его получения.
Пример ответа:
{{"decision": false, "explanation": "Текст понятен, и все предложения логически связаны между собой."}}
Если в тексте **есть** сложные предложения без логической связи между частями, **верни только** JSON {{"decision": true, "explanation": "<пояснение>"}};
если таких предложений **нет**, **верни только** JSON {{"decision": false, "explanation": "<пояснение>"}}.
**Не добавляй никакого дополнительного текста. Перед ответом убедись, что отвечаешь **только** в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)  # Задержка в 3 секунды между запросами
    print("GigaChat Pro response:", response)  # Выводим полный ответ модели
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Инвертируем логику
    else:
        return None

# 23. Проверка на близкие по смыслу однородные члены
def check_synonymous_members(message):
    print()
    print("Проверка 23: Проверка на близкие по смыслу однородные члены")
    print()
    message_clean = cut_message(message)
    prompt = f'''Проверь следующий текст на наличие однородных членов предложения, которые имеют одинаковый или практически одинаковый смысл и повторяют одну и ту же идею:
"{message_clean}"
Обрати внимание, что слова или выражения могут описывать разные аспекты продукта или услуги, и это не считается избыточным, если они не полностью дублируют значение друг друга. Например, такие слова как "премиальная" и "бизнес" могут описывать разные качества и не должны считаться синонимами.
Пример ответа:
{{"decision": true, "explanation": "В предложении используются синонимы 'быстрый' и 'скорый', которые повторяют одну и ту же идею."}}
Если такие слова или выражения есть, **верни только** JSON {{"decision": true, "explanation": "<пояснение>"}};
если таких слов или выражений нет, **верни только** JSON {{"decision": false, "explanation": "<пояснение>"}}.
**Не добавляй никакого дополнительного текста. Перед ответом убедись, что отвечаешь только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Инвертируем логику
    else:
        return None


# 24. Проверка на шокирующие, экстравагантные или кликбейтные фразы
def check_clickbait_phrases(message):
    message_clean = cut_message(message)
    print()
    print()
    print("СООБЩЕНИЕ:", message_clean)
    print()
    print("Первая группа проверок на LLM")
    print()
    print("Проверка 24: Проверка на шокирующие, экстравагантные или кликбейтные фразы")
    print()
    prompt = f'''Проверь следующий текст на наличие шокирующих, экстравагантных или кликбейтных фраз:
    "{message_clean}"
    Инструкции:
    1. Игнорируй фразы, которые основаны на фактической информации, даже если они выглядят сенсационно, такие как "лимит до миллиона" или "льготный период до 365 дней". Если эти данные подтверждаются и не являются преувеличением, их не следует считать кликбейтом.
    2. Ищи фразы, которые явно преувеличивают или вводят в заблуждение, обещая нечто чрезмерно идеализированное или сенсационное, что не может быть доказано или подтверждено. Примеры кликбейтных фраз: "Шокирующая правда", "Вы не поверите, что произошло", "Это изменит вашу жизнь за один день".
    3. Стандартные рекламные призывы к действию, такие как "купите сейчас" или "узнайте больше", не считаются кликбейтом, если они не преувеличивают преимущества или не используют явную манипуляцию эмоциями.
    Пример ответа:
    {{"decision": false, "explanation": "Текст нейтрален и не содержит кликбейтных фраз."}}
    
    Если текст содержит кликбейтные фразы, **верни только** JSON {{"decision": true, "explanation": "<пояснение>"}}; 
    если таких фраз нет, **верни только** JSON {{"decision": false, "explanation": "<пояснение>"}}.
    
    **Не добавляй никакого дополнительного текста. Перед ответом убедись, что отвечаешь только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Инвертируем логику
    else:
        return None


# 25. Проверка на абстрактные заявления без поддержки фактами
def check_abstract_claims(message):
    print()
    print("Проверка 25: Проверка на абстрактные заявления без поддержки фактами")
    print()
    message_clean = cut_message(message)
    prompt = f'''Проверь следующий текст на наличие чрезмерно абстрактных или неподкрепленных фактическими данными утверждений, которые могут усложнить понимание преимуществ продукта или услуги:
    "{message_clean}"
    
    Инструкции:
    1. Исключи фразы, которые содержат конкретные числовые данные, обещания о времени выполнения или другие факты, которые могут быть проверены (например, "от 1 минуты", "24/7", "в течение 24 часов").
    2. Не считай абстрактными фразами выражения, которые описывают конкретные выгодные условия, если они сопровождаются фактами или цифрами (например, "выгодные условия при покупке от 100 000 рублей" или "индивидуальные условия с процентной ставкой 3%").
    3. Помечай абстрактными фразами любые утверждения, которые звучат эмоционально, но не сопровождаются конкретикой, такие как:
       - "выгодное финансирование"
       - "развивайте свой бизнес быстрее"
       - "повышение эффективности"
       - "эффективное управление"
       - "надёжное решение"
       - "оптимизируйте управление финансами"
       - "выгодные условия для бизнеса"
       - "лёгкие условия и кэшбэк"
       - "мобильно, удобно, комфортно".
    4. Ищи общие фразы, которые не дают представления о конкретной пользе, такие как "лучшее решение", "высокое качество", "отличный сервис", если они не сопровождаются пояснением о том, почему это так.
    5. Учитывай, что в рекламных сообщениях допустимы эмоциональные и обобщённые фразы, если они достаточно конкретны для понимания аудитории, однако они должны сопровождаться фактами или подробными примерами. 
    
    Пример ответа:
    {{"decision": false, "explanation": "Текст не содержит абстрактные утверждения без конкретики."}}
    
    Если в тексте присутствуют абстрактные или неподкрепленные заявления, **верни только** JSON {{"decision": true, "explanation": "<пояснение>"}}; 
    если таких утверждений нет, **верни только** JSON {{"decision": false, "explanation": "<пояснение>"}}.
    
    **Не добавляй никакого дополнительного текста. Перед ответом убедись, что отвечаешь только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Инвертируем логическое значение
    else:
        return None


# 26. Проверка на узкоспециализированные термины
def check_specialized_terms(message):
    print()
    print("Проверка 26: Проверка на узкоспециализированные термины")
    print()
    message_clean = cut_message(message)
    prompt = f'''Проверь следующий текст на наличие узкоспециализированных терминов или жаргона, которые могут быть непонятны широкой аудитории:
    "{message_clean}"
    
    Инструкции:
    1. Игнорируй общеупотребительные термины, известные широкой аудитории, такие как "ИП", "ООО", "РФ", а также термины, связанные с обычными финансовыми продуктами (например, "кредитная карта", "интернет-банк", "Mastercard").
    2. Ищи термины, характерные для узких профессиональных областей, таких как медицина, ИТ, право, инженерия и другие специализированные сферы.
    3. Пример специализированных терминов: "интероперабельность", "кибернетика", "гипертензия", "аутентификация" и т.п.
    
    Определи, содержит ли текст термины, которые известны только специалистам в определенной области и могут вызвать затруднения у обычных читателей.
    
    Пример ответа:
    {{"decision": false, "explanation": "В тексте отсутствуют узкоспециализированные термины."}}
    
    Если в тексте есть такие узкоспециализированные термины, **верни только** JSON {{"decision": true, "explanation": "<пояснение>"}}; 
    если таких терминов нет, **верни только** JSON {{"decision": false, "explanation": "<пояснение>"}}.
    
    **Не добавляй никакого дополнительного текста. Перед ответом убедись, что отвечаешь только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Инвертируем логическое значение
    else:
        return None

# 27. Проверка на двусмысленные или обидные фразы
def check_offensive_phrases(message):
    print()
    print("Проверка 27: Проверка на двусмысленные или обидные фразы")
    print()
    message_clean = cut_message(message)
    prompt = f'''Проверь следующий текст на наличие фраз, которые могут быть истолкованы двусмысленно или вызвать негативные эмоции у читателя:
"{message_clean}"
Определи, есть ли в тексте выражения, которые могут быть восприняты как оскорбительные, обидные или неуместные.
Обрати внимание, что фразы, используемые в обычном деловом контексте и не содержащие явных оскорблений, дискриминации или непристойностей, не считаются проблемными.
Например, фразы, объясняющие преимущества продукта, такие как "без отчётов и комиссий", являются допустимыми.
Пример ответа:
{{"decision": false, "explanation": "Текст не содержит обидных или двусмысленных фраз."}}
Если такие фразы есть, **верни только** JSON {{"decision": true, "explanation": "<пояснение>"}};
если таких фраз нет, **верни только** JSON {{"decision": false, "explanation": "<пояснение>"}}.
**Не добавляй никакого дополнительного текста. Перед ответом убедись, что отвечаешь только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Инвертируем логическое значение
    else:
        return None

# 28. Проверка на речевые клише, рекламные штампы и канцеляризмы
def check_cliches_and_bureaucratese(message):
    print()
    print("Проверка 28: Проверка на речевые клише, рекламные штампы и канцеляризмы")
    print()
    message_clean = cut_message(message)
    prompt = f'''Проверь следующий текст на наличие речевых клише, излишне употребляемых фраз, рекламных штампов и канцеляризмов, которые делают текст менее выразительным и оригинальным: 
    "{message_clean}" 
    Обрати внимание **только** на избитые фразы, которые чрезмерно используются в рекламных текстах и не несут дополнительной ценности. 
    **Не считай клише или канцеляризмами следующие типы выражений:**
    - Стандартные призывы к действию (например, "Получите", "Оформите", "Закажите сейчас"), но **не** их комбинации с общими, неопределёнными фразами, как например, "за считанные минуты", "быстро, удобно".
    - Информацию о ценах, скидках, акциях или условиях покупки (например, "при покупках от 100 000 рублей в месяц").
    - Описания способов оформления или получения услуг (например, "оформление возможно онлайн или в офисе").
    - Стандартные отраслевые термины и фразы, необходимые для понимания сообщения (например, "премиальная бизнес-карта", "Mastercard Preffered"), но **не** их использование в комбинации с общими словами, как например, "идеальное решение для вашего бизнеса".
    **Считай клише или канцеляризмами следующие типы выражений:**
    - Избитые фразы, такие как:
      - "Обеспечьте стабильность и развитие вашего бизнеса"
      - "Заботьтесь о будущем семьи, сохраняя ресурсы."
      - "Получите необходимые средства для развития бизнеса и обеспечения финансовой стабильности!"
      - "Ваш бизнес ждёт выгодное финансирование! Развивайте свой бизнес быстрее!"
      - "Без лишней волокиты"
      - "Быстро, удобно, без лишних хлопот!"
      - "За считанные минуты"
      - "Это идеальное предложение для вашего бизнеса!"
      - "Удобное и надёжное решение для роста вашего капитала".
    Пример ответа:
    {{"decision": false, "explanation": "Текст не содержит клише или канцеляризмов."}}
    Если в тексте **нет** таких выражений, **верни только** JSON {{"decision": false, "explanation": "<пояснение>"}};
    если в тексте **есть** такие выражения, **верни только** JSON {{"decision": true, "explanation": "<пояснение>"}}.
    **Не добавляй никакого дополнительного текста. Перед ответом убедись, что отвечаешь только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision
    else:
        return None

# 29. Проверка на соответствие описанию предложения
def check_no_contradictions(message, description):
    print()
    print("Проверка 29: Проверка на отсутствие противоречий с описанием предложения")
    print()
    message_clean = cut_message(message)
    prompt = f'''Проверь, не противоречит ли следующее сообщение описанию предложения.
Описание предложения:
"{description}"
Сообщение:
"{message}"
Если сообщение не содержит фактов, которые отсутствуют в описании предложения, **верни только** JSON {{"decision": false, "explanation": "Противоречий не обнаружено."}}.
Если сообщение содержит факты, которые отсутствуют в описании предложения, **верни только** JSON {{"decision": true, "explanation": "<описание противоречий>"}}.
**Не добавляй никакого дополнительного текста. Отвечай только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Возвращаем True, если противоречий нет
    else:
        return None

# 30. Проверка на наличие ключевого сообщения
def check_contains_key_message(message, key_message):
    print()
    print("Проверка 30: Проверка на наличие ключевого сообщения")
    print()
    message_clean = cut_message(message)
    prompt = f'''Проверь, содержит ли следующее сообщение ключевое сообщение.
Сообщение:
"{message}"
Ключевой текст:
"{key_message}"
Если сообщение **содержит всю** информацию из ключевого текста, **верни только** JSON {{"decision": false, "explanation": "Ключевое текст присутствует."}}.
Если сообщение **не содержит всю** информацию из ключевого текста, **верни только** JSON {{"decision": true, "explanation": "Ключевое текст отсутствует."}}.
**Не добавляй никакого дополнительного текста. Отвечай только в формате JSON с закрывающими кавычками и скобками.**'''

    response = generate_check_gigachat_pro(prompt)
    time.sleep(3)
    print("GigaChat Pro response:", response)
    result = parse_json_response(response)
    if result is not None:
        decision = result.get("decision", False)
        explanation = result.get("explanation", "")
        print("Explanation:", explanation)
        return not decision  # Возвращаем True, если ключевое сообщение присутствует
    else:
        return None

# ФУНКЦИИ ПРОВЕРОК (КОНЕЦ)


def safe_check(func, *args):
    try:
        return func(*args)
    except Exception as e:
        # Optionally, you can log the exception here if needed
        return None  # Indicate that the check could not be performed

def perform_checks(message, description, key_message):
    checks = {}

    # 2. Morphological checks using pymorphy2
    morphological_checks = [
        ("forbidden_words", check_forbidden_words),
        ("client_addressing", check_no_greeting),
        ("promises", check_no_promises),
        ("double_verbs", check_no_double_verbs),
        ("participles", check_no_participles),
        ("adverbial_participles", check_no_adverbial_participles),
        ("superlative_adjectives", check_no_superlative_adjectives),
        ("passive_voice", check_no_passive_voice),
        ("written_out_ordinals", check_no_written_out_ordinals),
        ("subordinate_clauses_chain", check_no_subordinate_clauses_chain),
        ("repeating_conjunctions", check_no_repeating_conjunctions),
        ("introductory_phrases", check_no_introductory_phrases),
        ("amplifiers", check_no_amplifiers),
        ("time_parasites", check_no_time_parasites),
        ("multiple_nouns", check_no_multiple_nouns),
        ("derived_prepositions", check_no_derived_prepositions),
        ("compound_sentences", check_no_compound_sentences),
        ("dates_written_out", check_no_dates_written_out),
        ("no_word_repetitions", check_no_word_repetitions),
    ]

    # 3. LLM checks: check_clickbait_phrases, check_abstract_claims, check_cliches_and_bureaucratese
    llm_checks_group1 = [
        ("clickbait_phrases", check_clickbait_phrases),
        ("abstract_claims", check_abstract_claims),
        ("cliches_and_bureaucratese", check_cliches_and_bureaucratese),
    ]

    # 4. Remaining LLM checks
    llm_checks_group2 = [
        ("disconnected_sentences", check_disconnected_sentences),
        ("synonymous_members", check_synonymous_members),
        ("specialized_terms", check_specialized_terms),
        ("offensive_phrases", check_offensive_phrases),
        ("no_contradictions", check_no_contradictions),
        ("contains_key_message", check_contains_key_message),
    ]

    # Perform morphological checks
    for check_name, check_func in morphological_checks:
        result = safe_check(check_func, message)
        checks[check_name] = result
        if result is False:
            return checks  # Stop on first failure

    # Perform LLM checks group 1
    for check_name, check_func in llm_checks_group1:
        result = safe_check(check_func, message)
        checks[check_name] = result
        if result is False:
            return checks  # Stop on first failure

    # Perform remaining LLM checks
    for check_name, check_func in llm_checks_group2:
        if check_name == "no_contradictions":
            result = safe_check(check_func, message, description)
        elif check_name == "contains_key_message":
            result = safe_check(check_func, message, key_message)
        else:
            result = safe_check(check_func, message)
        checks[check_name] = result
        if result is False:
            return checks  # Stop on first failure

    return checks  # All checks passed


def format_checks(checks):
    translation = {
        "forbidden_words": "Запрещенные слова",
        "client_addressing": "Обращение к клиенту",
        "promises": "Обещания и гарантии",
        "double_verbs": "Два глагола подряд",
        "participles": "Причастия",
        "adverbial_participles": "Деепричастия",
        "superlative_adjectives": "Превосходная степень",
        "passive_voice": "Страдательный залог",
        "written_out_ordinals": "Порядковые числительные",
        "subordinate_clauses_chain": "Цепочки с придаточными предложениями",
        "repeating_conjunctions": "Разделительные повторяющиеся союзы",
        "introductory_phrases": "Вводные конструкции",
        "amplifiers": "Усилители",
        "time_parasites": "Паразиты времени",
        "multiple_nouns": "Несколько существительных подряд",
        "derived_prepositions": "Производные предлоги",
        "compound_sentences": "Сложноподчиненные предложения",
        "dates_written_out": "Даты прописью",
        "no_word_repetitions": "Повторы слов",
        # Проверки на LLM
        "disconnected_sentences": "Сложные предложения без логической связи",
        "synonymous_members": "Близкие по смыслу однородные члены предложения",
        "clickbait_phrases": "Кликбейтные фразы",
        "abstract_claims": "Абстрактные заявления без доказательств",
        "specialized_terms": "Узкоспециализированные термины",
        "offensive_phrases": "Двусмысленные или оскорбительные фразы",
        "cliches_and_bureaucratese": "Речевые клише, рекламные штампы, канцеляризмы",
        "no_contradictions": "Отсутствие противоречий с описанием предложения",
        "contains_key_message": "Наличие ключевого сообщения"
    }
    formatted_results = []
    for rule, result in checks.items():
        if result is True:
            symbol = '✔️'
        elif result is False:
            symbol = '❌'
        else:
            symbol = '❓'  # Indicates that the check could not be performed
        formatted_results.append(f"{translation[rule]}: {symbol}")
    return "  \n".join(formatted_results)


# Функция для обработки нажатия кнопки "Проверить"
def perform_all_checks_and_show_results(personalized_message_1, personalized_message_2, personalized_message_3):
    # Моментально показываем все персонализированные сообщения
    yield (
        personalized_message_1, None,  # Первое сообщение без проверки
        personalized_message_2, None,  # Второе сообщение без проверки
        personalized_message_3, None,  # Третье сообщение без проверки
        None, None, None  # Пустые графики для спидометров
    )
    
    # Выполняем и показываем проверки с задержкой 1 секунда
    checks_1 = perform_checks(personalized_message_1)
    formatted_checks_1 = format_checks(checks_1)
    time.sleep(1)  # Задержка 1 секунда перед выводом первого результата проверки
    yield (
        personalized_message_1, formatted_checks_1,  # Проверка для первого сообщения
        personalized_message_2, None,  # Второе сообщение без проверки
        personalized_message_3, None,  # Третье сообщение без проверки
        None, None, None  # Пустые графики для спидометров
    )
    
    checks_2 = perform_checks(personalized_message_2)
    formatted_checks_2 = format_checks(checks_2)
    time.sleep(1)  # Задержка 1 секунда перед выводом второго результата проверки
    yield (
        personalized_message_1, formatted_checks_1,  # Проверка для первого сообщения
        personalized_message_2, formatted_checks_2,  # Проверка для второго сообщения
        personalized_message_3, None,  # Третье сообщение без проверки
        None, None, None  # Пустые графики для спидометров
    )
    
    checks_3 = perform_checks(personalized_message_3)
    formatted_checks_3 = format_checks(checks_3)
    time.sleep(1)  # Задержка 1 секунда перед выводом третьего результата проверки
    yield (
        personalized_message_1, formatted_checks_1,  # Проверка для первого сообщения
        personalized_message_2, formatted_checks_2,  # Проверка для второго сообщения
        personalized_message_3, formatted_checks_3,  # Проверка для третьего сообщения
        None, None, None  # Пустые графики для спидометров
    )

    # Генерация и показ графиков спидометров с задержкой 2 секунды
    time.sleep(2)
    gauges = generate_random_gauges()
    yield (
        personalized_message_1, formatted_checks_1,  # Проверка для первого сообщения
        personalized_message_2, formatted_checks_2,  # Проверка для второго сообщения
        personalized_message_3, formatted_checks_3,  # Проверка для третьего сообщения
        gauges[0], None, None  # Первый график спидометра
    )
    
    time.sleep(2)
    yield (
        personalized_message_1, formatted_checks_1,  # Проверка для первого сообщения
        personalized_message_2, formatted_checks_2,  # Проверка для второго сообщения
        personalized_message_3, formatted_checks_3,  # Проверка для третьего сообщения
        gauges[0], gauges[1], None  # Первый и второй графики спидометра
    )
    
    time.sleep(2)
    yield (
        personalized_message_1, formatted_checks_1,  # Проверка для первого сообщения
        personalized_message_2, formatted_checks_2,  # Проверка для второго сообщения
        personalized_message_3, formatted_checks_3,  # Проверка для третьего сообщения
        gauges[0], gauges[1], gauges[2]  # Все три графика спидометра
    )


# Интерфейс Gradio
with gr.Blocks() as demo:
    # Твой интерфейс

    with gr.Tabs() as tabs:
        
        # Вкладка 1: Исходные данные
        with gr.TabItem("Исходные данные", id=0):
            with gr.Row():
                with gr.Column():
                    desc = gr.Textbox(
                        label="Описание предложения (предзаполненный пример можно поменять на свой)", 
                        lines=7,
                        value=(
                            "Необходимо предложить клиенту оформить дебетовую премиальную бизнес-карту Mastercard Preffered. "
                            "Обслуживание карты стоит 700 рублей в месяц, но клиент может пользоваться ей бесплатно. "
                            "Что необходимо сделать, чтобы воспользоваться предложением:\n"
                            "1. Оформить премиальную бизнес-карту в офисе банка или онлайн в интернет-банке СберБизнес.\n"
                            "2. Забрать карту.\n"
                            "3. В течение календарного месяца совершить по ней покупки на сумму от 100 000 рублей.\n"
                            "4. В течение следующего месяца пользоваться ей бесплатно."
                        )
                    )
                    benefits = gr.Textbox(
                        label="Преимущества (предзаполненный пример можно поменять на свой)", 
                        lines=5,
                        value=(
                            "Предложение по бесплатному обслуживанию — бессрочное.\n"
                            "Оплата покупок без отчётов и платёжных поручений.\n"
                            "Платёжные документы без комиссии.\n"
                            "Лимиты на расходы сотрудников.\n"
                            "Мгновенные переводы на карты любых банков."
                        )
                    )
                    
                    key_message = gr.Textbox(
                        label="Ключевое сообщение (предзаполненный пример можно поменять на свой)",
                        lines=3,
                        value="Бесплатное обслуживание при покупках от 100 000 рублей в месяц."
                    )

                with gr.Column():
                    gender = gr.Dropdown(label="Пол", choices=[None] + list(features.get('Пол', {}).keys()))
                    generation = gr.Dropdown(label="Поколение", choices=[None] + list(features.get('Поколение', {}).keys()))
                    psychotype = gr.Dropdown(label="Психотип", choices=[None] + list(features.get('Психотип', {}).keys()))
                    business_stage = gr.Dropdown(label="Стадия бизнеса", choices=[None] + list(features.get('Стадия бизнеса', {}).keys()))
                    industry = gr.Dropdown(label="Отрасль", choices=[None] + list(features.get('Отрасль', {}).keys()))
                    opf = gr.Dropdown(label="ОПФ", choices=[None] + list(features.get('ОПФ', {}).keys()))
            btn_to_prompts = gr.Button("Создать")
            
        # Вкладка 2: Промпты
        with gr.TabItem("Ассистент", id=1):
            with gr.Row():
                with gr.Column():
                    non_personalized_prompt = gr.Textbox(
                        label="Задание для копирайтера", 
                        lines=25,
                        interactive=False)
                with gr.Column():
                    personalized_prompt = gr.Textbox(label="Задание для редактора", lines=25)  # Увеличенная высота
                    
        # Вкладка 3: Сообщения
        with gr.TabItem("Сообщения", id=2):
            with gr.Row():
                gr.Markdown("### Копирайтер")
                gr.Markdown("### Редактор")
                
            with gr.Row():
                non_personalized_1 = gr.Textbox(label="Стандартное сообщение 1", lines=4, interactive=False)
                personalized_1 = gr.Textbox(label="Персонализированное сообщение 1", lines=4, interactive=False)

            with gr.Row():
                non_personalized_2 = gr.Textbox(label="Стандартное сообщение 2", lines=4, interactive=False)
                personalized_2 = gr.Textbox(label="Персонализированное сообщение 2", lines=4, interactive=False)

            with gr.Row():
                non_personalized_3 = gr.Textbox(label="Стандартное сообщение 3", lines=4, interactive=False)
                personalized_3 = gr.Textbox(label="Персонализированное сообщение 3", lines=4, interactive=False)

            # Четвертый ряд
            with gr.Row():
                btn_check = gr.Button("Проверить", elem_id="check3")
                btn_check.click(fn=change_tab, inputs=[gr.Number(value=3, visible=False)], outputs=tabs)

            # Сначала переключаем вкладку, потом запускаем генерацию сообщений
            btn_to_prompts.click(
                fn=change_tab, 
                inputs=[gr.Number(value=1, visible=False)],  # Переключение на вкладку "Ассистент" (id=1)
                outputs=tabs  # Обновляем вкладку
            ).then(
                fn=generate_all_messages, 
                inputs=[desc, benefits, key_message, gender, generation, psychotype, business_stage, industry, opf],  # Входные текстовые поля
                outputs=[
                    non_personalized_prompt, personalized_prompt,  # Поля для задания копирайтера и редактора (на вкладке "Ассистент")
                    non_personalized_1, personalized_1,  # Сообщения на вкладке "Сообщения"
                    non_personalized_2, personalized_2,
                    non_personalized_3, personalized_3
                ]
            )

        # Вкладка 4: Проверка
        with gr.TabItem("Проверка", id=3):
            with gr.Row():
                gr.Markdown("### Редактор")
                gr.Markdown("### Корректор")
                gr.Markdown("### Аналитик")
                
            with gr.Row():
                personalized_message_1 = gr.Textbox(label="Персонализированное сообщение 1", lines=5, interactive=False)
                check_message_1 = gr.Textbox(label="Проверка сообщения 1", lines=5, interactive=False)
                with gr.Column():
                    gr.HTML("<div style='display:flex; justify-content:center; width:100%;'>")
                    success_forecast_1 = gr.Plot(label="Прогноз успешности сообщения 1")
                    gr.HTML("</div>")
            
            with gr.Row():
                personalized_message_2 = gr.Textbox(label="Персонализированное сообщение 2", lines=5)
                check_message_2 = gr.Textbox(label="Проверка сообщения 2", lines=5, interactive=False)
                with gr.Column():
                    gr.HTML("<div style='display:flex; justify-content:center; width:100%;'>")
                    success_forecast_2 = gr.Plot(label="Прогноз успешности сообщения 2")
                    gr.HTML("</div>")
            
            with gr.Row():
                personalized_message_3 = gr.Textbox(label="Персонализированное сообщение 3", lines=5, interactive=False)
                check_message_3 = gr.Textbox(label="Проверка сообщения 3", lines=5, interactive=False)              
                with gr.Column():
                    gr.HTML("<div style='display:flex; justify-content:center; width:100%;'>")
                    success_forecast_3 = gr.Plot(label="Прогноз успешности сообщения 3")
                    gr.HTML("</div>")
                
            # Модифицируем нажатие кнопки "Проверить"
            btn_check.click(
                fn=change_tab, 
                inputs=[gr.Number(value=3, visible=False)],  # Переключение на вкладку "Проверка"
                outputs=tabs  # Обновляем вкладку
            ).then(
                fn=perform_all_checks_and_show_results,
                inputs=[personalized_1, personalized_2, personalized_3],  # Входные персонализированные сообщения
                outputs=[
                    personalized_message_1, check_message_1,  # Результаты проверок для первого сообщения
                    personalized_message_2, check_message_2,  # Результаты проверок для второго сообщения
                    personalized_message_3, check_message_3   # Результаты проверок для третьего сообщения
                ]
            ).then(
                fn=generate_random_gauges, 
                inputs=[],  # Нет входных данных для спидометров
                outputs=[success_forecast_1, success_forecast_2, success_forecast_3]  # Вывод значений спидометров
            )

demo.launch()