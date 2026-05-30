# frozen_string_literal: true
#
# FLOWXE Legal — генератор страниц юридических документов.
#
# Что делает плагин:
#   1. Сканирует _docs/<lang>/<doc>/<version>.md
#   2. Для каждого языка/документа определяет наибольшую версию как текущую
#   3. Валидирует, что версии синхронны между языками
#   4. Генерирует страницы:
#        /<lang>/<doc>/                — актуальная версия
#        /<lang>/<doc>/<version>/      — конкретная версия (с пометкой "архив", если не текущая)
#        /<lang>/<doc>/changelog/      — журнал изменений
#        /<lang>/                      — список всех документов
#
# Метаданные в файле версии (YAML front matter):
#   ---
#   version: v2.0           # обязательно, должен совпадать с именем файла
#   effective_date: 2026-05-30  # обязательно, дата вступления в силу
#   summary: |              # опционально (fallback на _data/changelog.yml)
#     Описание изменений в этой редакции.
#   ---

require 'yaml'
require 'date'

module FlowxeLegal
  # Сравнение версий вида "v1.0", "v2.0", "v2.1", "v10.0".
  # Возвращает <0, 0 или >0 как обычный <=>.
  def self.compare_versions(a, b)
    pa = a.sub(/^v/, '').split('.').map { |x| x.to_i }
    pb = b.sub(/^v/, '').split('.').map { |x| x.to_i }
    # Дополняем нулями до одинаковой длины, чтобы v1 == v1.0.
    len = [pa.length, pb.length].max
    pa.fill(0, pa.length, len - pa.length)
    pb.fill(0, pb.length, len - pb.length)
    pa <=> pb
  end

  # Локализованные строки для шаблонов — чтобы layout'ы не были захламлены условиями.
  STRINGS = {
    'ru' => {
      'documents'         => 'Документы',
      'changelog'         => 'История изменений',
      'effective_from'    => 'действует с',
      'archived_banner'   => 'Вы просматриваете архивную редакцию <strong>%{version}</strong>.',
      'open_current'      => 'Открыть актуальную редакцию (%{version})',
      'open_version'      => 'Открыть версию →',
      'current_label'     => 'текущая',
      'no_summary'        => '—',
      'doc_titles'        => {
        'privacy' => 'Политика конфиденциальности',
        'terms'   => 'Правила пользования',
        'offer'   => 'Публичная оферта',
        'refund'  => 'Условия возврата',
      },
      'index_title'       => 'Юридические документы',
      'index_subtitle'    => 'Актуальные редакции документов, регулирующих использование сервиса FLOWXE Network.',
    },
    'en' => {
      'documents'         => 'Documents',
      'changelog'         => 'Changelog',
      'effective_from'    => 'effective from',
      'archived_banner'   => 'You are viewing archived version <strong>%{version}</strong>.',
      'open_current'      => 'Open the current version (%{version})',
      'open_version'      => 'Open version →',
      'current_label'     => 'current',
      'no_summary'        => '—',
      'doc_titles'        => {
        'privacy' => 'Privacy Policy',
        'terms'   => 'Terms of Service',
        'offer'   => 'Public Offer',
        'refund'  => 'Refund Policy',
      },
      'index_title'       => 'Legal documents',
      'index_subtitle'    => 'Current versions of documents governing the use of FLOWXE Network.',
    },
  }.freeze
end

# ──────────────────────────────────────────────────────────────────────────────
# Жизненный цикл Jekyll:
# 1. :post_read — все коллекции и файлы прочитаны. Здесь мы делаем валидацию
#    и сохраняем сводку версий в site.data['versions'] для доступа из шаблонов.
# 2. Generator#generate — здесь мы создаём новые страницы.
# ──────────────────────────────────────────────────────────────────────────────

Jekyll::Hooks.register :site, :post_read do |site|
  docs_dir = File.join(site.source, '_docs')
  unless Dir.exist?(docs_dir)
    raise "FLOWXE Legal: directory _docs not found at #{docs_dir}"
  end

  # Сканируем структуру: _docs/<lang>/<doc>/<version>.md
  inventory = {}  # { 'privacy' => { 'ru' => ['v1.0','v2.0'], 'en' => [...] }, ... }
  languages = site.config['languages'] || ['ru', 'en']

  Dir.glob(File.join(docs_dir, '*', '*', '*.md')).sort.each do |path|
    rel = path.sub(docs_dir + '/', '')
    parts = rel.split('/')
    next unless parts.length == 3
    lang, doc, file = parts
    version = File.basename(file, '.md')

    # Базовая проверка — версия должна быть валидной.
    unless version =~ /\Av\d+(\.\d+)*\z/
      raise "FLOWXE Legal: invalid version name '#{version}' in #{rel} " \
            "(expected format v1.0, v2.1, v3, …)"
    end

    inventory[doc] ||= {}
    inventory[doc][lang] ||= []
    inventory[doc][lang] << version
  end

  if inventory.empty?
    raise "FLOWXE Legal: no documents found in _docs/"
  end

  # ────────────────────────────────────────────────────────────────────────
  # Валидация синхронности языков.
  # Для каждого документа множества версий по языкам должны совпадать.
  # ────────────────────────────────────────────────────────────────────────
  inventory.each do |doc, by_lang|
    missing_langs = languages - by_lang.keys
    unless missing_langs.empty?
      raise "FLOWXE Legal: document '#{doc}' is missing translations for: " \
            "#{missing_langs.join(', ')}. Expected files in _docs/<lang>/#{doc}/."
    end

    # Все языки должны иметь одинаковый набор версий.
    by_lang.each_value(&:sort!)
    reference_lang = languages.first
    reference_versions = by_lang[reference_lang]
    by_lang.each do |lang, versions|
      next if versions.sort == reference_versions.sort
      raise "FLOWXE Legal: version mismatch in '#{doc}': " \
            "#{reference_lang} has [#{reference_versions.join(', ')}], " \
            "#{lang} has [#{versions.join(', ')}]. " \
            "Both languages must have the same set of versions."
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # Сборка сводки версий — попадает в site.data['versions']
  # и доступна в шаблонах как site.data.versions.<doc>.
  # ────────────────────────────────────────────────────────────────────────
  versions_data = {}
  inventory.each do |doc, by_lang|
    versions = by_lang.values.first.sort { |a, b| FlowxeLegal.compare_versions(a, b) }
    current = versions.last

    # Собираем метаданные каждой версии — из front matter файлов, fallback на _data/changelog.yml.
    entries = versions.map do |ver|
      entry = { 'version' => ver }

      # По умолчанию пытаемся достать summary и дату из _data/changelog.yml.
      changelog_data = site.data.dig('changelog', doc) || []
      fallback = changelog_data.find { |e| e['version'] == ver } || {}

      languages.each do |lang|
        file_path = File.join(docs_dir, lang, doc, "#{ver}.md")
        next unless File.exist?(file_path)

        # Жёстко парсим front matter сами, чтобы не зависеть от стадии загрузки документа в Jekyll.
        content = File.read(file_path, encoding: 'UTF-8')
        front_matter = {}
        if content =~ /\A---\s*\n(.*?)\n---\s*\n/m
          # permitted_classes = [Date], потому что effective_date парсится как Date.
          front_matter = YAML.safe_load(Regexp.last_match(1), permitted_classes: [Date]) || {}
        end

        # Проверка: version в файле должна совпадать с именем файла.
        if front_matter['version'] && front_matter['version'] != ver
          raise "FLOWXE Legal: in #{lang}/#{doc}/#{ver}.md, front matter " \
                "version is '#{front_matter['version']}' but filename is '#{ver}.md'. " \
                "These must match."
        end

        entry['effective_date'] ||= front_matter['effective_date'] || fallback['date']
        # Поддерживаем оба формата:
        #  - "summary_ru:" и "summary_en:" в одном файле (для всех языков сразу), и
        #  - просто "summary:" в файле своего языка.
        # Так удобнее: переводчик может оставить summary только в своём файле,
        # либо редактор может задать summary сразу на обоих языках в RU-файле.
        languages.each do |l|
          key = "summary_#{l}"
          entry[key] ||= front_matter[key] || (front_matter['summary'] if lang == l) || fallback[key]
        end
      end

      # Если дата не задана — это ошибка для текущей версии (на главной нужно её показать).
      if entry['effective_date'].nil? && ver == current
        raise "FLOWXE Legal: missing effective_date for current version " \
              "#{ver} of '#{doc}'. Set it in the file's front matter."
      end

      entry
    end

    versions_data[doc] = {
      'current'  => current,
      'versions' => versions,
      'entries'  => entries.reverse,  # самая новая — сверху, для changelog и главной
    }
  end

  site.data['versions'] = versions_data
end


# ──────────────────────────────────────────────────────────────────────────────
# Генератор страниц.
# ──────────────────────────────────────────────────────────────────────────────
module FlowxeLegal
  class PageGenerator < Jekyll::Generator
    safe true
    priority :normal

    def generate(site)
      languages = site.config['languages'] || ['ru', 'en']
      versions_data = site.data['versions']
      return unless versions_data

      languages.each do |lang|
        # 1. Главная страница: /<lang>/
        site.pages << IndexPage.new(site, lang, versions_data)

        # 2. Для каждого документа — актуальная страница, страницы версий, changelog.
        versions_data.each do |doc, info|
          # /ru/privacy/ — актуальная (содержимое последней версии)
          site.pages << DocumentPage.new(site, lang, doc, info['current'], info, current: true)

          # /ru/privacy/v2.0/, /ru/privacy/v1.0/ … — каждая версия
          info['versions'].each do |version|
            is_current = version == info['current']
            site.pages << DocumentPage.new(site, lang, doc, version, info, current: is_current, archived_url: !is_current)
          end

          # /ru/privacy/changelog/
          site.pages << ChangelogPage.new(site, lang, doc, info)
        end
      end
    end
  end

  # Главная страница языка.
  class IndexPage < Jekyll::Page
    def initialize(site, lang, versions_data)
      @site = site
      @base = site.source
      @dir  = "/#{lang}/"
      @name = 'index.html'
      strings = FlowxeLegal::STRINGS[lang]
      process(@name)
      self.content = ''
      self.data = {
        'layout'        => 'index',
        'lang'          => lang,
        'title'         => strings['index_title'],
        'description'   => strings['index_subtitle'],
        # versions_data сюда передаём как массив пар, чтобы итерация в Liquid
        # сохраняла порядок (хеши в YAML/JSON-сериализации Liquid могут терять его).
        'versions_data' => versions_data.to_a,
        'strings'       => strings,
      }
    end
  end

  # Страница документа конкретной версии или актуальной.
  class DocumentPage < Jekyll::Page
    def initialize(site, lang, doc, version, info, current:, archived_url: false)
      @site = site
      @base = site.source
      strings = FlowxeLegal::STRINGS[lang]

      # archived_url=true означает /lang/doc/vX.Y/, иначе /lang/doc/.
      @dir  = archived_url ? "/#{lang}/#{doc}/#{version}/" : "/#{lang}/#{doc}/"
      @name = 'index.html'
      process(@name)

      # Содержимое подгружаем из _docs/<lang>/<doc>/<version>.md, отрезая front matter.
      file_path = File.join(site.source, '_docs', lang, doc, "#{version}.md")
      raw = File.read(file_path)
      body = raw.sub(/\A---\s*\n.*?\n---\s*\n/m, '')

      entry = info['entries'].find { |e| e['version'] == version } || {}

      # Канонический URL: если у нас две страницы с одинаковым контентом
      # (актуальная и архивная для текущей версии), canonical всегда указывает
      # на короткий URL без номера версии — это говорит поисковикам, какая страница главная.
      canonical = "/#{lang}/#{doc}/"

      self.content = body
      self.data = {
        'layout'         => 'document',
        'lang'           => lang,
        'doc'            => doc,
        'doc_title'      => strings['doc_titles'][doc],
        'version'        => version,
        'current_version'=> info['current'],
        'is_current'     => current,
        'is_archived'    => !current,
        'show_archived_banner' => !current && archived_url,
        'effective_date' => entry['effective_date'],
        'canonical_url'  => canonical,
        # Дубликаты в индексе нам не нужны: страницу /ru/privacy/v2.0/, когда v2.0 —
        # это текущая версия, помечаем noindex. Архивные версии тоже noindex —
        # они нужны для ссылок, но не для поиска.
        'noindex'        => archived_url,
        'title'          => current ? strings['doc_titles'][doc] : "#{strings['doc_titles'][doc]} #{version}",
        'strings'        => strings,
      }
    end
  end

  # Страница журнала изменений.
  class ChangelogPage < Jekyll::Page
    def initialize(site, lang, doc, info)
      @site = site
      @base = site.source
      @dir  = "/#{lang}/#{doc}/changelog/"
      @name = 'index.html'
      strings = FlowxeLegal::STRINGS[lang]
      process(@name)
      self.content = ''
      self.data = {
        'layout'         => 'changelog',
        'lang'           => lang,
        'doc'            => doc,
        'doc_title'      => strings['doc_titles'][doc],
        'title'          => "#{strings['changelog']} — #{strings['doc_titles'][doc]}",
        'current_version'=> info['current'],
        'entries'        => info['entries'],
        'strings'        => strings,
      }
    end
  end
end
