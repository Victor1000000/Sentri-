import type { Locale } from '../../domain/types.js';
import type { InboxKind } from './types.js';

/**
 * Alert wording, shown inside the app and as the notification text. Not SMS, so accents are fine.
 * ha / yo / ig / pcm are working drafts: have native speakers review them before launch, especially
 * "do not call" in the duress text.
 * {n} is the sender's name, or a neutral word when they did not give one.
 */
const T: Record<Locale, Record<InboxKind, string>> & Record<Locale, { someone: string }> = {
  en: {
    someone: 'Someone',
    sos: '{n} needs urgent help. Open Sentri to see where they are and call the police near them.',
    duress: '{n} may be in danger and under pressure. Do NOT call them. Open Sentri to call the police near them.',
    offline: "{n}'s phone went offline during an alert. Open Sentri for the last place.",
    low_battery: "{n}'s phone battery is nearly dead. Open Sentri for the last place.",
    test: '{n} sent a test alert. Nothing to do. A real alert looks like this.',
    share_start: '{n} is sharing their location with you. Open Sentri to follow along.',
    share_stop: '{n} stopped sharing their location with you.',
  },
  pcm: {
    someone: 'Person',
    sos: '{n} dey need help sharp sharp. Open Sentri see where e dey and call police wey dey near am.',
    duress: '{n} fit dey danger, dem dey force am. No call am. Open Sentri to call police wey dey near am.',
    offline: "{n} phone don go offline for alert. Open Sentri see last place.",
    low_battery: "{n} phone battery don almost finish. Open Sentri see last place.",
    test: '{n} send test alert. Nothing to do. Real alert go look like this.',
    share_start: '{n} dey share where e dey with you. Open Sentri to follow am.',
    share_stop: '{n} don stop to share where e dey.',
  },
  ha: {
    someone: 'Wani',
    sos: '{n} na bukatar taimako gaggawa. Buɗe Sentri ka ga inda yake ka kira ’yan sanda mafi kusa da shi.',
    duress: '{n} na iya kasancewa cikin hatsari ana tilasta shi. Kar ka kira shi. Buɗe Sentri ka kira ’yan sanda mafi kusa da shi.',
    offline: 'Wayar {n} ta kashe yayin gargaɗi. Buɗe Sentri ka ga wurin ƙarshe.',
    low_battery: 'Cajin wayar {n} ya kusa ƙarewa. Buɗe Sentri ka ga wurin ƙarshe.',
    test: '{n} ya aiko gwajin gargaɗi. Babu abin yi. Gargaɗin gaske zai yi kama da wannan.',
    share_start: '{n} na raba maka wurin da yake. Buɗe Sentri ka bi sawunsa.',
    share_stop: '{n} ya daina raba maka wurin da yake.',
  },
  yo: {
    someone: 'Ẹnìkan',
    sos: '{n} nílò ìrànlọ́wọ́ kíákíá. Ṣí Sentri láti rí ibi tí ó wà kí o sì pe ọlọ́pàá tó sún mọ́ ọn.',
    duress: '{n} lè wà nínú ewu, wọ́n ń fipá mú un. Má pè é. Ṣí Sentri kí o pe ọlọ́pàá tó sún mọ́ ọn.',
    offline: 'Fóònù {n} ti pa nígbà ìkìlọ̀. Ṣí Sentri fún ibi ìgbẹ̀yìn.',
    low_battery: 'Bátìrì fóònù {n} ti fẹ́rẹ̀ parí. Ṣí Sentri fún ibi ìgbẹ̀yìn.',
    test: '{n} fi ìdánwò ìkìlọ̀ ránṣẹ́. Kò sí ohun tí o máa ṣe. Ìkìlọ̀ gidi á rí báyìí.',
    share_start: '{n} ń pín ibi tí ó wà pẹ̀lú rẹ. Ṣí Sentri láti tẹ̀lé e.',
    share_stop: '{n} ti dáwọ́ pípín ibi tí ó wà dúró.',
  },
  ig: {
    someone: 'Mmadụ',
    sos: '{n} chọrọ enyemaka ozugbo. Meghee Sentri ka i hụ ebe ọ nọ ma kpọọ ndị uwe ojii dị ya nso.',
    duress: '{n} nwere ike ịnọ n’ihe ize ndụ, a na-amanye ya. Akpọla ya. Meghee Sentri ka i kpọọ ndị uwe ojii dị ya nso.',
    offline: 'Ekwentị {n} gbanyụrụ n’oge ọkwa. Meghee Sentri maka ebe ikpeazụ.',
    low_battery: 'Batrị ekwentị {n} dị nso n’ọgwụgwụ. Meghee Sentri maka ebe ikpeazụ.',
    test: '{n} zitere ọkwa nnwale. Ọ nweghị ihe ị ga-eme. Ọkwa n’ezie ga-adị otu a.',
    share_start: '{n} na-ekekọrịta ebe ọ nọ gị. Meghee Sentri iji soro ya.',
    share_stop: '{n} akwụsịla ịkekọrịta ebe ọ nọ.',
  },
};

export function alertText(kind: InboxKind, locale: Locale, name?: string | null): string {
  const t = T[locale] ?? T.en;
  return t[kind].replace('{n}', name?.trim() || t.someone);
}

export const ALL_ALERT_TEXTS = T;
