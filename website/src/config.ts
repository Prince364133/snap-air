// One place for everything that changes between releases or deployments.
export const SITE = {
  name: 'Snapy',
  domain: 'snappy.live',
  url: 'https://snappy.live',
  tagline: 'The private AI assistant for Windows',
  description:
    'Snapy is a private AI assistant for Windows. Talk to it in English, Hindi or Hinglish to control your PC, click and type on screen, take meeting notes, set reminders and plan your day — with the AI running on your own laptop.',
  locale: 'en_IN',
  company: 'Snapy',
  jurisdiction: 'India',
  email: {
    support: 'support@snappy.live',
    privacy: 'privacy@snappy.live',
    security: 'security@snappy.live',
    legal: 'legal@snappy.live',
  },
  legalUpdated: '15 November 2026',
};

export const RELEASE = {
  version: '2.0.0',
  date: '2026-11-15',
  dateLabel: '15 November 2026',
  file: 'Snapy-Setup-2.0.0.exe',
  // Where the installer is hosted (a CDN / object storage URL). Static hosts like
  // GitHub Pages can't serve a 358 MB file, so this is configurable.
  downloadUrl: '/download/Snapy-Setup-2.0.0.exe',
  sizeMB: 358,
  sha256: 'c7a3664c2f8e7a99fb8f513f5795db0273a53dc40bae8c654997aa82b9111351',
  os: 'Windows 10 (64-bit, version 1903+) or Windows 11',
};

export const NAV = [
  { href: '/features/', label: 'Features' },
  { href: '/commands/', label: 'Commands' },
  { href: '/install/', label: 'Install guide' },
  { href: '/faq/', label: 'FAQ' },
  { href: '/support/', label: 'Support' },
];

export const FOOTER = [
  {
    title: 'Product',
    links: [
      { href: '/features/', label: 'All features' },
      { href: '/features/voice/', label: 'Voice assistant' },
      { href: '/features/screen-control/', label: 'Screen control' },
      { href: '/features/memory/', label: 'Memory & routines' },
      { href: '/features/meetings/', label: 'Meeting notes' },
      { href: '/features/indian-languages/', label: 'Hindi & Indian languages' },
      { href: '/commands/', label: 'Voice commands' },
    ],
  },
  {
    title: 'Get Snapy',
    links: [
      { href: '/download/', label: 'Download for Windows' },
      { href: '/install/', label: 'How to install' },
      { href: '/system-requirements/', label: 'System requirements' },
      { href: '/changelog/', label: 'Release notes' },
    ],
  },
  {
    title: 'Help',
    links: [
      { href: '/faq/', label: 'FAQ' },
      { href: '/support/', label: 'Support' },
      { href: '/security/', label: 'Security' },
      { href: '/about/', label: 'About' },
    ],
  },
  {
    title: 'Legal',
    links: [
      { href: '/privacy/', label: 'Privacy policy' },
      { href: '/terms/', label: 'Terms of service' },
      { href: '/eula/', label: 'License agreement (EULA)' },
    ],
  },
];
