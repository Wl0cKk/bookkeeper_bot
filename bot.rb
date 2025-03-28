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
    rescue SQLite3::Exception => e
        puts ''
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

def send_category_selection(bot, db, chat_id)
    db.execute("UPDATE users SET chat_status = 'def' WHERE chat_id = ?", [chat_id])
    res = db.execute("SELECT msg_id, language_ind FROM users WHERE chat_id = ?", [chat_id]).first
    begin
      bot.api.delete_message(chat_id: chat_id, message_id: res['msg_id'])
    rescue Telegram::Bot::Exceptions::ResponseError => e
    end
  
    text = res['language_ind'] == 0 ? "Choose a category of costs" : "Выбери категорию расходов"
    
    categories_buttons = CATEGORIES.reject { |k, _| ['Date', 'Photo', 'Description'].include?(k) }.map do |key, names|
      Telegram::Bot::Types::InlineKeyboardButton.new(
        text: names[res['language_ind']],
        callback_data: "category_#{key}"
      )
    end
  
    keyboard = categories_buttons.each_slice(2).to_a
    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
    
    msg = bot.api.send_message(
      chat_id: chat_id,
      text: text,
      reply_markup: markup
    )
    
    db.execute("UPDATE users SET msg_id = ? WHERE chat_id = ?", [msg.message_id, chat_id])
end

def create_csv(chat_id)
    CSV.open("#{chat_id}.csv", "wb") do |csv|
    end
end

def reset(chat_id)
    create_csv(chat_id)
end

def status(bot, db, chat_id)
    user = db.execute("SELECT language_ind FROM users WHERE chat_id = ?", [chat_id]).first
    return unless user
    language_ind = user['language_ind']
    reversed_categories = CATEGORIES.each_with_object({}) { |(k, v), h| h[v[0]] = k }
    sums = Hash.new(0.0)
    total_sum = 0.0
    if File.exist?("#{chat_id}.csv")
        CSV.foreach("#{chat_id}.csv") do |row|
            next if row.size < 3
            category_eng = row[1]
            amount = row[2].to_f rescue 0.0
            key = reversed_categories[category_eng]
            if key
                sums[key] += amount
                total_sum += amount
            end
        end
    end
    output = []
    CATEGORIES.each do |key, names|
        next if ['Date', 'Photo', 'Description'].include?(key)
        category_name = names[language_ind]
        total = sums.fetch(key, 0.0).round(2)
        output << "#{category_name}: #{total}"
    end
    total_text = language_ind == 0 ? "-------------------\nTotal" : "-------------------\nВсего"
    output << "\n#{total_text}: #{total_sum.round(2)}"
    text = output.join("\n")
    bot.api.send_message(chat_id: chat_id, text: text)
    rescue => e
    puts "Error in status: #{e.message}"
end

begin
Telegram::Bot::Client.run(TOKEN) { |bot|
    bot.listen { |message|
        Thread.start(message) { |message| 
            case message
            when Telegram::Bot::Types::Message
                chat_id = message.chat.id
                if Time.now.to_i - message.date > 5
                    puts "skip #{message.from.id}\t|#{message}|\n"
                    next
                end
                exist = db.execute("SELECT 1 FROM users WHERE chat_id = ?", [chat_id])[0]
                unless exist
                    case message.text
                    when '/start'
                        DB_MUTEX.synchronize {
                            db.execute(
                                "INSERT OR IGNORE INTO users (chat_id, username, first_name, last_name) VALUES (?, ?, ?, ?)",
                                [chat_id, message.from.username || nil, message.from.first_name,  message.from.last_name || '']
                            )
                        }
                        msg = bot.api.send_message(
                            chat_id: message.chat.id,
                            text: 'Please choose your language / Пожалуйста, выберите язык:',
                            reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(keyboard: [[{ text: 'EN' }, { text: 'RU' }]], one_time_keyboard: true, resize_keyboard: true)
                        )
                        db.execute("UPDATE users SET msg_id = ? WHERE chat_id = ?", [msg.message_id, chat_id])
                        create_csv("#{chat_id}")
                    end
                else
                    case db.execute("SELECT chat_status FROM users WHERE chat_id = $1", [chat_id]).first['chat_status']
                    when 'def'
                        case message.text
                        when 'EN', 'RU'
                            res = db.execute("SELECT language_ind, chat_status, msg_id FROM users WHERE chat_id = ?", [chat_id]).first
                            if res.any?
                                curr = res['language_ind']
                                new_lang = message.text == 'EN' ? 0 : 1
                                db.execute("UPDATE users SET language_ind = ?, chat_status = ? WHERE chat_id = ?", [new_lang, 'def', chat_id])
                                if new_lang == 0
                                    text = "Language successfully changed"
                                    kb = '👉 Bill'
                                elsif new_lang == 1
                                    text = "Язык успешно сменен"
                                    kb = '👉 Чек'
                                end
                                begin
                                    bot.api.delete_message(chat_id: chat_id, message_id: res['msg_id'])
                                rescue Telegram::Bot::Exceptions::ResponseError => e
                                end
                                msg = bot.api.send_message(chat_id: chat_id, text: text, reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(keyboard: [[{text: kb}]], one_time_keyboard: true, resize_keyboard: true))
                                db.execute("UPDATE users SET msg_id = ? WHERE chat_id = ?", [msg.message_id, chat_id])
                            end
                        when /\s*(Чек|Bill)\s*/i
                            send_category_selection(bot, db, chat_id)
                        when '/status'
                            status(bot, db, chat_id)
                        when '/reset'
                            reset(chat_id)
                            lang = db.execute("SELECT language_ind FROM users WHERE chat_id = ?", [chat_id]).first['language_ind']
                            text = lang == 0 ? "All data has been reset" : "Все данные сброшены"
                            bot.api.send_message(chat_id: chat_id, text: text)
                        end
                    when 'payment'
                        res = db.execute("SELECT msg_id, language_ind, category FROM users WHERE chat_id = $1", [chat_id]).first
                        amount = if message.caption
                            message.caption.match(/\d+(\.\d+)?/)&.[](0) || false
                        else
                            false
                        end
                        if !message.photo || !(amount)
                            text = if res['language_ind'] == 0
                              "You must send a photo and the amount in one message"
                            else
                              "Вы должны отправить фотографию и сумму одним сообщением"
                            end
                            bot.api.send_message(chat_id: chat_id, text: text)
                          else
                            begin
                                bot.api.delete_message(chat_id: chat_id, message_id: res['msg_id'])
                            rescue Telegram::Bot::Exceptions::ResponseError => e
                            end
                            db.execute("UPDATE users SET chat_status = 'def' WHERE chat_id = ?", [chat_id])
                            
                            date = Time.now.strftime("%Y-%m-%d")
                            photo_file_id = message.photo.last.file_id
                            category = CATEGORIES[res['category']][0]

                            CSV.open("#{chat_id}.csv", "a+") do |csv|
                                csv << [date, category, amount, photo_file_id]
                            end
                            confirmation_text = res['language_ind'] == 0 ? "Accepted! ✅" : "Принято! ✅"
                            button_text = res['language_ind'] == 0 ? "👉Bill" : "👉Чек"
                            msg = bot.api.send_message(
                                chat_id: chat_id,
                                text: confirmation_text,
                                reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(
                                    keyboard: [[{text: button_text}]],
                                    one_time_keyboard: true,
                                    resize_keyboard: true
                                )
                            )
                        end
                    end
                end
            when Telegram::Bot::Types::CallbackQuery
                chat_id = message.from.id
                case message.data
                when /^category_/
                    callback_id = message.id
                    data = message.data.split('_').last
                    bot.api.answer_callback_query(callback_query_id: callback_id, text: data)
                    db.execute("UPDATE users SET chat_status = 'payment' WHERE chat_id = ?", [chat_id])
                    res = db.execute("SELECT * FROM users WHERE chat_id = ?", [chat_id]).first
                    if res['language_ind'] == 0
                        text = "Send the bill picture with caption of amount spent"
                        back = "⬅️ Back"
                    else
                        text = "Отправь фото счета и затраченную сумму одним сообщением"
                        back = "⬅️ Отмена"
                    end
                    markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(
                        inline_keyboard: [[{ text: back, callback_data: 'back' }]]
                    )
                    msg = bot.api.edit_message_text(chat_id: chat_id, message_id: res['msg_id'], text: text, reply_markup: markup)
                    db.execute("UPDATE users SET msg_id = ?, category = ? WHERE chat_id = ?", [msg.message_id, data, chat_id])
                when 'back'
                    send_category_selection(bot, db, chat_id)
                end
            end
        } # thread
    } # listen
} # Telegram
rescue Interrupt
    db.close if db
    puts "\rBye\n\n"
    exit
end

