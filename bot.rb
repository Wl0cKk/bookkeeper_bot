require_relative 'config'
require 'telegram/bot'
require 'sqlite3'
require 'csv'

DB_MUTEX = Mutex.new
DB_FILE = 'users.db'

db = SQLite3::Database.new(DB_FILE)
db.results_as_hash = true

DB_MUTEX.synchronize {
    begin
        db.execute <<-SQL
            CREATE TABLE users (
                user_id      INTEGER  PRIMARY KEY,
                created_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
                chat_id      TEXT,
                chat_status  TEXT DEFAULT 'def',
                username     TEXT,
                first_name   TEXT,
                last_name    TEXT,
                category     TEXT,
                msg_id       INTEGER,
                language_ind INTEGER,
                record_row   INTEGER 
            );
        SQL
    rescue SQLite3::Exception
    end
    puts "#{Time.now} | Running!"
}

CATEGORIES = {
    'Date'                    => ['Date'                    ,'Дата'                   ],
    'other-costs'             => ['Other costs'             ,'Прочие расходы'         ], # 2
    'housing'                 => ['Housing'                 ,'Жилье'                  ], # 3
    'food'                    => ['Food'                    ,'Питание'                ], # 4
    'transportation'          => ['Transportation'          ,'Транспорт'              ], # 5 
    'health'                  => ['Health'                  ,'Здоровье'               ], # 6
    'clothing-and-footwear'   => ['Clothing and footwear'   ,'Одежда и обувь'         ], # 7
    'entertainment'           => ['Entertainment'           ,'Развлечения'            ], # 8
    'education'               => ['Education'               ,'Образование'            ], # 9
    'personal-care'           => ['Personal care'           ,'Личные расходы'         ], # 10
    'travel'                  => ['Travel'                  ,'Путешествия'            ], # 11
    'children'                => ['Children'                ,'Дети'                   ], # 12
    'pets'                    => ['Pets'                    ,'Домашние животные'      ], # 13
    'electronics-and-gadgets' => ['Electronics and gadgets' ,'Техника и гаджеты'      ], # 14
    'taxes-and-insurance'     => ['Taxes and insurance'     ,'Налоги и страховки'     ], # 15
    'credits-and-debts'       => ['Credits and debts'       ,'Кредиты и долги'        ], # 16
    'savings-and-investments' => ['Savings and investments' ,'Сбережения и инвестиции'], # 17
    'Photo'                   => ['Photo'                   ,'Фото'                   ],
    'Description'             => ['Description'             ,'Описание'               ]
}
.freeze

class DBHelper
    def self.user_data(db, chat_id, *fields)
        db.execute("SELECT #{fields.join(',')} FROM users WHERE chat_id = ?", [chat_id]).first
    end

    def self.update_user(db, chat_id, **updates)
        set_clause = updates.map { |k, _| "#{k} = ?" }.join(', ')
        values = updates.values + [chat_id]
        db.execute("UPDATE users SET #{set_clause} WHERE chat_id = ?", values)
    end

    def self.create_user(db, chat_id, user_data)
        db.execute(
            "INSERT OR IGNORE INTO users (chat_id, username, first_name, last_name) VALUES (?, ?, ?, ?)",
            [chat_id, user_data[:username], user_data[:first_name], user_data[:last_name]]
        )
    end
end

class TextHelper
    MESSAGES = {
        category_selection: ['Choose a category of costs', 'Выбери категорию расходов'],
        amount_request: ['Send the bill picture with caption of amount spent', 'Отправь фото счета и затраченную сумму одним сообщением'],
        back_button: ['⬅️ Back', '⬅️ Отмена'],
        choose_language: ['Please choose your language / Пожалуйста, выберите язык:'],
        language_changed: ['Language successfully changed', 'Язык успешно сменен'],
        main_button: ['👉 Bill', '👉 Чек'],
        reset_confirmation: ['All data has been reset', 'Все данные сброшены'],
        status_total: ['Total', 'Всего'],
        payment_error: ['You must send a photo and the amount in one message', 'Вы должны отправить фотографию и сумму одним сообщением'],
        payment_success: ['Accepted! ✅', 'Принято! ✅'],
        start_button: ['EN', 'RU']
    }.freeze

    def self.get(message_key, lang_index)
        MESSAGES[message_key][lang_index] rescue MESSAGES[message_key].first
    end

    def self.category_name(category_key, lang_index)
        CATEGORIES[category_key][lang_index]
    end
end

def send_category_selection(bot, db, chat_id)
    user = DBHelper.user_data(db, chat_id, :msg_id, :language_ind)
    DBHelper.update_user(db, chat_id, chat_status: 'def')
    
    delete_message(bot, chat_id, user['msg_id'])
    
    text = TextHelper.get(:category_selection, user['language_ind'])
    buttons = category_buttons(user['language_ind'])
    
    send_message_with_markup(bot, db, chat_id, text, buttons)
end

def category_buttons(lang_index)
    categories = CATEGORIES.reject { |k, _| %w[Date Photo Description].include?(k) }
    categories.map { |key, names|
        Telegram::Bot::Types::InlineKeyboardButton.new(
            text: names[lang_index],
            callback_data: "category_#{key}"
        )
    }.each_slice(2).to_a
end

def delete_message(bot, chat_id, message_id)
    bot.api.delete_message(chat_id: chat_id, message_id: message_id)
rescue Telegram::Bot::Exceptions::ResponseError
end

def send_message_with_markup(bot, db, chat_id, text, buttons)
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: buttons)
    msg = bot.api.send_message(chat_id: chat_id, text: text, reply_markup: markup)
    DBHelper.update_user(db, chat_id, msg_id: msg.message_id)
    msg
end

def create_csv(chat_id)
    CSV.open("#{chat_id}.csv", "wb") { |csv| }
end

def reset(chat_id)
    create_csv(chat_id)
end

def status(bot, db, chat_id)
    user = DBHelper.user_data(db, chat_id, :language_ind)
    return unless user

    sums = calculate_category_sums(chat_id)
    output = build_status_output(sums, user['language_ind'])
    bot.api.send_message(chat_id: chat_id, text: output)
rescue => e
    puts "Error in status: #{e.message}"
end

def calculate_category_sums(chat_id)
    sums = Hash.new(0.0)
    return sums unless File.exist?("#{chat_id}.csv")

    CSV.foreach("#{chat_id}.csv") { |row|
        next if row.size < 3
        category_eng = row[1]
        amount = row[2].to_f rescue 0.0
        key = CATEGORIES.find { |_, v| v[0] == category_eng }&.first
        sums[key] += amount if key
    }
    sums
end

def build_status_output(sums, lang_index)
    output = []
    CATEGORIES.each { |key, names|
        next if %w[Date Photo Description].include?(key)
        output << "#{names[lang_index]}: #{sums.fetch(key, 0.0).round(2)}"
    }
    
    total = sums.values.sum.round(2)
    total_text = TextHelper.get(:status_total, lang_index)
    output << "\n-------------------\n#{total_text}: #{total}"
    output.join("\n")
end

def handle_message(bot, db, message)
    chat_id = message.chat.id
    return if Time.now.to_i - message.date > 5

    case message.text
    when '/start'
        handle_start(bot, db, chat_id, message.from)
    when '/status'
        status(bot, db, chat_id)
    when '/reset'
        handle_reset(bot, db, chat_id)
    else
        handle_regular_message(bot, db, chat_id, message)
    end
end

def handle_start(bot, db, chat_id, user)
    DBHelper.create_user(db, chat_id, {
        username: user.username,
        first_name: user.first_name,
        last_name: user.last_name || ''
    })

    msg = bot.api.send_message(
        chat_id: chat_id,
        text: TextHelper.get(:choose_language, 0),
        reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(
            keyboard: [[
                { text: TextHelper.get(:start_button, 0) }, 
                { text: TextHelper.get(:start_button, 1) }
            ]],
            one_time_keyboard: true,
            resize_keyboard: true
        )
    )
    DBHelper.update_user(db, chat_id, msg_id: msg.message_id)
end

def handle_reset(bot, db, chat_id)
    reset(chat_id)
    user = DBHelper.user_data(db, chat_id, :language_ind)
    bot.api.send_message(
        chat_id: chat_id,
        text: TextHelper.get(:reset_confirmation, user['language_ind'])
    )
end

def handle_regular_message(bot, db, chat_id, message)
    user = DBHelper.user_data(db, chat_id, :chat_status, :msg_id, :language_ind, :category)
    return unless user

    case user['chat_status']
    when 'def'
        handle_def_status(bot, db, chat_id, message, user)
    when 'payment'
        handle_payment(bot, db, chat_id, message, user)
    end
end

def handle_def_status(bot, db, chat_id, message, user)
    case message.text
    when /(Чек|Bill)/i
        send_category_selection(bot, db, chat_id)
    when 'EN', 'RU'
        handle_language_change(bot, db, chat_id, message.text, user)
    end
end

def handle_language_change(bot, db, chat_id, lang, user)
    new_lang = lang == 'EN' ? 0 : 1
    DBHelper.update_user(db, chat_id, 
        language_ind: new_lang,
        chat_status: 'def'
    )

    delete_message(bot, chat_id, user['msg_id'])
    confirmation = TextHelper.get(:language_changed, new_lang)
    button_text = TextHelper.get(:main_button, new_lang)

    msg = bot.api.send_message(
        chat_id: chat_id,
        text: confirmation,
        reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(
            keyboard: [[{ text: button_text }]],
            one_time_keyboard: true,
            resize_keyboard: true
        )
    )
    DBHelper.update_user(db, chat_id, msg_id: msg.message_id)
end

def handle_payment(bot, db, chat_id, message, user)
    amount = parse_amount(message)
    if valid_payment?(message, amount)
        process_payment(bot, db, chat_id, message, user, amount)
    else
        send_payment_error(bot, chat_id, user)
    end
end

def parse_amount(message)
    if message.caption
        message.caption.match(/\d+(\.\d+)?/)&.[](0)
    else
        false
    end
end

def valid_payment?(message, amount)
    message.photo && amount
end

def process_payment(bot, db, chat_id, message, user, amount)
    delete_message(bot, chat_id, user['msg_id'])
    DBHelper.update_user(db, chat_id, chat_status: 'def')

    save_to_csv(chat_id, user, amount, message.photo.last.file_id)

    confirmation = TextHelper.get(:payment_success, user['language_ind'])
    button_text = TextHelper.get(:main_button, user['language_ind'])

    msg = bot.api.send_message(
        chat_id: chat_id,
        text: confirmation,
        reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(
            keyboard: [[{ text: button_text }]],
            one_time_keyboard: true,
            resize_keyboard: true
        )
    )
    DBHelper.update_user(db, chat_id, msg_id: msg.message_id)
end

def save_to_csv(chat_id, user, amount, file_id)
    CSV.open("#{chat_id}.csv", "a+") { |csv|
        csv << [
            Time.now.strftime("%Y-%m-%d"),
            TextHelper.category_name(user['category'], 0),
            amount,
            file_id
        ]
    }
end

def send_payment_error(bot, chat_id, user)
    bot.api.send_message(
        chat_id: chat_id,
        text: TextHelper.get(:payment_error, user['language_ind'])
    )
end

def handle_callback(bot, db, callback)
    chat_id = callback.from.id
    case callback.data
    when /^category_/
        handle_category_selection(bot, db, chat_id, callback)
    when 'back'
        send_category_selection(bot, db, chat_id)
    end
end

def handle_category_selection(bot, db, chat_id, callback)
    category = callback.data.split('_').last
    bot.api.answer_callback_query(callback_query_id: callback.id, text: category)
    
    DBHelper.update_user(db, chat_id, chat_status: 'payment', category: category)
    user = DBHelper.user_data(db, chat_id, :msg_id, :language_ind)

    text = TextHelper.get(:amount_request, user['language_ind'])
    back_button = Telegram::Bot::Types::InlineKeyboardButton.new(
        text: TextHelper.get(:back_button, user['language_ind']),
        callback_data: 'back'
    )

    msg = bot.api.edit_message_text(
        chat_id: chat_id,
        message_id: user['msg_id'],
        text: text,
        reply_markup: Telegram::Bot::Types::InlineKeyboardMarkup.new(
            inline_keyboard: [[back_button]]
        )
    )
    DBHelper.update_user(db, chat_id, msg_id: msg.message_id)
end

begin
    Telegram::Bot::Client.run(TOKEN) { |bot|
        bot.listen { |message|
            Thread.start(message) { |message|
                case message
                when Telegram::Bot::Types::Message
                    handle_message(bot, db, message)
                when Telegram::Bot::Types::CallbackQuery
                    handle_callback(bot, db, message)
                end
            }
        }
    }
rescue Interrupt
    db.close if db
    puts "\rBye\n\n"
    exit
end