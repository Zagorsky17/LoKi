import { defineConfig } from 'vitepress'

const repo = 'https://github.com/ushan0v/forkop'

export default defineConfig({
  lang: 'ru-RU',
  title: 'Forkop',
  description: 'Маршрутизация трафика роутера OpenWrt по правилам: какие сайты и устройства через какой туннель',
  base: '/forkop/',
  cleanUrls: true,
  lastUpdated: true,
  srcExclude: ['README.md'],
  head: [
    ['meta', { name: 'theme-color', content: '#0d9488' }],
    ['meta', { property: 'og:title', content: 'Forkop' }],
    ['meta', { property: 'og:description', content: 'Маршрутизация трафика роутера OpenWrt по правилам' }],
  ],
  markdown: {
    container: {
      tipLabel: 'Совет',
      warningLabel: 'Внимание',
      dangerLabel: 'Опасно',
      infoLabel: 'Справка',
      detailsLabel: 'Подробнее',
      noteLabel: 'Заметка',
      importantLabel: 'Важно',
      cautionLabel: 'Осторожно',
    },
  },
  themeConfig: {
    // Groups without a heading: the theme draws a line between them and nothing else.
    sidebar: {
      '/': [
        {
          items: [
            { text: 'Установка и обновление', link: '/guide/install' },
            { text: 'Быстрый старт', link: '/guide/quick-start' },
          ],
        },
        {
          items: [
            { text: 'Секции', link: '/sections/' },
            { text: 'Встроенные списки', link: '/sections/lists' },
            { text: 'Наборы правил', link: '/sections/rule-sets' },
          ],
        },
        {
          items: [
            { text: 'URI подключения', link: '/connections/links' },
            { text: 'Подписка', link: '/connections/subscriptions' },
            { text: 'Сетевой интерфейс', link: '/connections/interface' },
            { text: 'JSON outbound', link: '/connections/json' },
          ],
        },
        {
          items: [
            { text: 'URLTest', link: '/connections/urltest' },
            { text: 'Fallback', link: '/connections/fallback' },
          ],
        },
        {
          items: [
            { text: 'DNS', link: '/dns/' },
            { text: 'Настройки', link: '/settings' },
            { text: 'Ошибки диагностики', link: '/troubleshooting/diagnostics' },
          ],
        },
      ],
    },
    socialLinks: [
      { icon: 'github', link: repo },
      { icon: 'telegram', link: 'https://t.me/forkop_chat' },
    ],
    editLink: {
      pattern: `${repo}/edit/main/docs/:path`,
      text: 'Исправить страницу на GitHub',
    },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: 'Поиск', buttonAriaLabel: 'Поиск' },
          modal: {
            displayDetails: 'Подробнее',
            resetButtonTitle: 'Сбросить',
            backButtonTitle: 'Закрыть',
            noResultsText: 'Ничего не нашлось по запросу',
            footer: { selectText: 'выбрать', navigateText: 'перейти', closeText: 'закрыть' },
          },
        },
      },
    },
    outline: { level: [2, 3], label: 'На этой странице' },
    docFooter: { prev: 'Назад', next: 'Дальше' },
    lastUpdated: { text: 'Обновлено' },
    darkModeSwitchLabel: 'Тема',
    lightModeSwitchTitle: 'Светлая тема',
    darkModeSwitchTitle: 'Тёмная тема',
    sidebarMenuLabel: 'Меню',
    returnToTopLabel: 'Наверх',
    langMenuLabel: 'Язык',
    notFound: {
      title: 'Страница не найдена',
      quote: 'Такой страницы нет. Возможно, её переименовали.',
      linkText: 'На главную',
    },
  },
})
