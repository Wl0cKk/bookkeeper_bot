require_relative 'config'
require 'telegram/bot'
require 'sqlite3'
require 'axlsx'

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
                msg_id       INTEGER,
                language_ind INTEGER
            );
        SQL
    rescue SQLite3::Exception => e
        puts ''
    end
    puts "#{Time.now} | DB created!"
}

CATEGORIES = {
    'Date'                    => [''                        ,''],
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
    'Photo'                   => [''                        ,''],
    'Description'             => [''                        ,'']
}

begin
Telegram::Bot::Client.run(TOKEN) { |bot|
    bot.listen { |message|
        Thread.start(message) { |message| 
            chat_id = message.chat.id
            case message
            when Telegram::Bot::Types::Message
                
                if Time.now.to_i - message.date > 5
                    puts "skip #{message.from.id}\t|#{message}|\n"
                    next
                end

                exist = db.execute("SELECT * FROM users WHERE chat_id = ?", [chat_id])[0]
                unless exist
                    case message.text
                    when '/start'

                        DB_MUTEX.synchronize {
                            db.execute(
                                "INSERT OR IGNORE INTO users (chat_id, username, first_name, last_name, chat_status) VALUES (?, ?, ?, ?, ?)",
                                [chat_id, message.from.username || nil, message.from.first_name,  message.from.last_name || '', 'from_beginning']
                            )
                        }
                        msg = bot.api.send_message(
                            chat_id: message.chat.id,
                            text: 'Please choose your language / Пожалуйста, выберите язык:',
                            reply_markup: Telegram::Bot::Types::ReplyKeyboardMarkup.new(keyboard: [[{ text: 'EN' }, { text: 'RU' }]], one_time_keyboard: true, resize_keyboard: true)
                        )
                        db.execute("UPDATE users SET msg_id = ? WHERE chat_id = ?", [msg.message_id, chat_id])
                    end
                else
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
                        res = db.execute("SELECT msg_id, language_ind FROM users WHERE chat_id = ?", [chat_id]).first
                        begin
                            bot.api.delete_message(chat_id: chat_id, message_id: res['msg_id'])
                        rescue Telegram::Bot::Exceptions::ResponseError => e
                        end
                        text = if res['language_ind'] == 0
                            "Choose a category"
                        else
                            "Выбери категорию"
                        end
                        categories_buttons = CATEGORIES.reject { |k, _| ['Date', 'Photo', 'Description'].include?(k) }.map do |key, names|
                            Telegram::Bot::Types::InlineKeyboardButton.new(
                                text: names[res['language_ind']],
                                callback_data: "category_#{key}"
                            )
                        end
                        keyboard = categories_buttons.each_slice(2).to_a
                        back_text = res['language_ind'] == 0 ? "Back" : "Назад"
                        keyboard << [Telegram::Bot::Types::InlineKeyboardButton.new(text: back_text, callback_data: "back")]
                        markup = Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: keyboard)
                        msg = bot.api.send_message(
                            chat_id: chat_id,
                            text: res['language_ind'] == 0 ? "Выберите категорию:" : "Select a category:",
                            reply_markup: markup
                        )
                        db.execute("UPDATE users SET msg_id = ? WHERE chat_id = ?", [msg.message_id, chat_id])
                    end
                end
            when Telegram::Bot::Types::CallbackQuery
                
            end
        } # thread
    } # listen
} # Telegram
rescue Interrupt
    db.close if db
    puts "\rBye\n\n"
    exit
end