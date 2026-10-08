/// Legal notice, privacy policy and terms of use: one source for the app
/// (LegalScreen) and the web pages (`dart run tool/generate_legal.dart`
/// writes web/legal/*.html, published with the web client).
///
/// Pure Dart, no Flutter. Every statement must stay true to the code: update
/// these texts with any change to what is stored, logged or sent, then bump
/// [kTermsVersion] (users accept again) and regenerate the pages.
library;

/// Publisher and publication director.
const kLegalPublisher = 'Kenn';

/// Contact for legal, privacy and abuse requests.
const kLegalContact = 'kennkerenbezara@gmail.com';

/// Minimum age to use Dismessage.
const kMinimumAge = 18;

/// Last change of these texts, shown in them.
const kLegalUpdated = '8 octobre 2026';

/// Accepted at first launch; a new value asks users to accept again.
const kTermsVersion = '2026-10-08';

/// A heading and its paragraphs. A paragraph starting with "- " is a bullet.
class LegalSection {
  const LegalSection(this.title, this.paragraphs);
  final String title;
  final List<String> paragraphs;
}

class LegalDocument {
  const LegalDocument({
    required this.slug,
    required this.title,
    required this.intro,
    required this.sections,
  });

  /// File name of the web page (`web/legal/<slug>.html`).
  final String slug;
  final String title;
  final String intro;
  final List<LegalSection> sections;
}

const _render =
    'Render Services, Inc., 525 Brannan Street, Suite 300, San Francisco, '
    'CA 94107, États-Unis. Téléphone : +1 415 319 8186. Site : render.com.';

const _github =
    'GitHub, Inc., 88 Colin P. Kelly Jr. Street, San Francisco, CA 94107, '
    'États-Unis. Téléphone : +1 877 448 4820. Site : github.com.';

const legalNotice = LegalDocument(
  slug: 'mentions-legales',
  title: 'Mentions légales',
  intro:
      'Informations prévues par l’article 6 de la loi n° 2004-575 du 21 juin '
      '2004 pour la confiance dans l’économie numérique (LCEN).',
  sections: [
    LegalSection('Éditeur', [
      'Dismessage est édité par $kLegalPublisher, particulier, à titre non '
          'professionnel et gratuit.',
      'Directeur de la publication : $kLegalPublisher.',
      'Contact : $kLegalContact.',
      'Conformément à l’article 6, III, 2 de la LCEN, l’éditeur, personne '
          'physique publiant à titre non professionnel, ne rend pas publics son '
          'adresse ni son numéro de téléphone : ses éléments d’identification '
          'sont tenus à la disposition de l’hébergeur ci-dessous.',
    ]),
    LegalSection('Hébergement', [
      'Serveur de messagerie (relais) : $_render',
      'Version web et code source : $_github',
    ]),
    LegalSection('Signaler un contenu ou un abus', [
      'Les messages étant chiffrés de bout en bout, l’éditeur ne peut ni les '
          'lire ni les modérer. Pour signaler un comportement illicite, écrivez '
          'à $kLegalContact en indiquant l’ID Dismessage concerné, la date et la '
          'nature des faits.',
      'Chacun peut aussi bloquer un ID dans l’application. En cas de danger '
          'ou d’infraction, adressez-vous aux autorités : la plateforme '
          'officielle de signalement est internet-signalement.gouv.fr (PHAROS).',
    ]),
    LegalSection('Propriété intellectuelle', [
      'Le nom, le logo et le code de Dismessage appartiennent à leur auteur. '
          'Le code source est consultable sur GitHub '
          '(github.com/Kenn555/Dismessage) ; sauf licence indiquée dans ce '
          'dépôt, sa réutilisation n’est pas autorisée.',
    ]),
  ],
);

const privacyPolicy = LegalDocument(
  slug: 'confidentialite',
  title: 'Politique de confidentialité',
  intro:
      'Dismessage est conçu pour garder le moins possible : pas de compte, '
      'pas d’adresse e-mail ni de numéro de téléphone demandés, et des '
      'messages qui ne sont enregistrés nulle part. Cette page détaille ce qui '
      'est traité, pourquoi, et combien de temps.',
  sections: [
    LegalSection('Responsable du traitement', [
      '$kLegalPublisher, éditeur de Dismessage. Contact : $kLegalContact.',
    ]),
    LegalSection('Ce qui reste sur votre appareil', [
      'Ces données ne quittent pas votre appareil et disparaissent quand vous '
          'désinstallez l’application (ou effacez les données du site, sur le '
          'web) :',
      '- votre ID Dismessage et le secret qui prouve qu’il vous appartient ;',
      '- vos contacts (un ID et le nom que vous leur donnez, jamais de '
          'message), vos IDs bloqués et vos réglages ;',
      '- l’adresse du serveur utilisé et votre acceptation des présentes '
          'conditions ;',
      '- les fichiers que vous acceptez de recevoir, enregistrés dans vos '
          'téléchargements.',
      'Les messages, photos et messages vocaux ne vivent qu’en mémoire, le '
          'temps de la conversation. Les photos envoyées sont débarrassées de '
          'leurs métadonnées EXIF, dont la position GPS.',
    ]),
    LegalSection('Ce que voit le serveur', [
      'Le serveur (relais) met en relation les utilisateurs et transmet leurs '
          'échanges. Il traite :',
      '- votre ID et une empreinte (hachage SHA-256) de son secret, pour '
          'empêcher qu’un autre ne s’en serve ; cette empreinte est effacée '
          'quand vous changez d’ID ou au redémarrage du serveur ;',
      '- votre adresse IP, pour la connexion et pour limiter les abus (nombre '
          'de connexions et de demandes par adresse), en mémoire seulement ;',
      '- les IDs que vous contactez, ceux qui vous contactent, et les IDs de '
          'vos contacts quand l’accueil affiche s’ils sont en ligne ; en '
          'mémoire seulement, le temps de la connexion.',
      'Le contenu des conversations (texte, frappe en direct, réactions, '
          'photos, vocaux, fichiers) est chiffré de bout en bout sur votre '
          'appareil : le serveur ne transmet que des données illisibles, et '
          'n’en garde rien. Seuls les deux participants détiennent les clés, '
          'créées pour chaque conversation puis oubliées.',
    ]),
    LegalSection('Journal du serveur', [
      'Pour la sécurité et le diagnostic, le serveur écrit un journal : '
          'connexions et déconnexions (adresse IP, ID), demandes et mises en '
          'relation (IDs concernés), limites atteintes. Il ne contient jamais '
          'de message ni de secret.',
      'Ce journal est conservé par l’hébergeur Render pendant 7 jours sur '
          'l’offre actuellement utilisée, puis effacé.',
    ]),
    LegalSection('Version web', [
      'La version web est hébergée par GitHub Pages, qui reçoit, comme tout '
          'hébergeur, l’adresse IP des visiteurs (voir la déclaration de '
          'confidentialité de GitHub). Pour afficher certains caractères '
          '(émojis, écritures rares), la page peut télécharger des polices '
          'depuis les serveurs de Google (fonts.gstatic.com), qui reçoivent '
          'alors votre adresse IP.',
      'Le site n’utilise ni cookie, ni outil de mesure d’audience, ni '
          'publicité. Le stockage local du navigateur sert uniquement à '
          'conserver les données listées plus haut, nécessaires au service.',
    ]),
    LegalSection('Autorisations demandées', [
      'Appareil photo, micro, photos et fichiers ne sont utilisés qu’au '
          'moment où vous prenez une photo, enregistrez un vocal ou choisissez '
          'un fichier à envoyer. Les notifications servent à vous prévenir des '
          'messages et demandes quand l’application n’est pas à l’écran ; '
          'elles sont produites par votre appareil, sans service de '
          'notification extérieur.',
    ]),
    LegalSection('Bases légales', [
      '- Fournir le service que vous demandez (article 6, 1, b du RGPD) : '
          'ID, mise en relation, transmission des messages.',
      '- Intérêt légitime à protéger le service contre les abus et à le '
          'maintenir (article 6, 1, f) : limites par adresse IP, journal.',
    ]),
    LegalSection('Destinataires et transferts hors de l’Union européenne', [
      'Aucune donnée n’est vendue ni partagée à des fins commerciales. Les '
          'seuls prestataires sont les hébergeurs Render (serveur) et GitHub '
          '(version web), tous deux établis aux États-Unis. Render adhère au '
          'cadre de protection des données UE–États-Unis (Data Privacy '
          'Framework) ; les transferts reposent sur ce cadre ou sur les '
          'garanties proposées par ces prestataires.',
    ]),
    LegalSection('Vos droits', [
      'Vous disposez des droits d’accès, de rectification, d’effacement, de '
          'limitation, d’opposition et de portabilité. Le serveur ne vous '
          'connaissant que par votre ID, indiquez-le dans votre demande à '
          '$kLegalContact. Vous pouvez aussi, à tout moment, générer un nouvel '
          'ID (l’ancien est effacé du serveur) ou désinstaller l’application.',
      'Vous pouvez introduire une réclamation auprès de la CNIL '
          '(cnil.fr).',
    ]),
    LegalSection('Âge minimum', [
      'Dismessage est réservé aux personnes de $kMinimumAge ans et plus.',
    ]),
  ],
);

const termsOfUse = LegalDocument(
  slug: 'conditions',
  title: 'Conditions d’utilisation',
  intro:
      'En utilisant Dismessage, vous acceptez les présentes conditions. Si '
      'vous ne les acceptez pas, n’utilisez pas le service.',
  sections: [
    LegalSection('Le service', [
      'Dismessage est une messagerie gratuite où l’on voit son '
          'interlocuteur écrire en direct. Chaque installation reçoit un ID à '
          '9 chiffres ; une conversation commence quand l’un demande et '
          'l’autre accepte. Les conversations sont chiffrées de bout en bout '
          'et ne sont enregistrées nulle part.',
    ]),
    LegalSection('Âge minimum', [
      'Vous devez avoir au moins $kMinimumAge ans pour utiliser Dismessage. '
          'En l’utilisant, vous déclarez avoir cet âge.',
    ]),
    LegalSection('Ce qui est interdit', [
      'Vous êtes seul responsable de ce que vous envoyez. Il est interdit '
          'd’utiliser Dismessage pour :',
      '- diffuser des contenus illicites, notamment pédopornographiques, '
          'terroristes, haineux, ou portant atteinte à la vie privée ou aux '
          'droits d’autrui ;',
      '- harceler, menacer, escroquer ou se faire passer pour quelqu’un '
          'd’autre ;',
      '- envoyer des demandes ou des messages en masse, ou des fichiers '
          'malveillants ;',
      '- perturber le service, contourner ses limites ou tenter de prendre '
          'l’ID d’un autre.',
      'L’éditeur peut restreindre ou couper l’accès au service en cas '
          'd’abus, et coopère avec les autorités dans les cas prévus par la '
          'loi, dans la limite de ce qu’il détient (voir la politique de '
          'confidentialité : il n’a pas accès au contenu des conversations).',
    ]),
    LegalSection('Prudence', [
      'Ne partagez votre ID qu’avec des personnes de confiance, et bloquez '
          'celles qui vous dérangent. Un fichier reçu peut être dangereux : '
          'n’ouvrez que ceux que vous attendiez. Le code de sécurité d’une '
          'conversation (« Vérifier le chiffrement ») permet de vérifier, de '
          'vive voix, que personne ne s’est interposé.',
    ]),
    LegalSection('Disponibilité et responsabilité', [
      'Le service est fourni gratuitement, tel quel, sans garantie de '
          'disponibilité : il peut être interrompu, ralenti (le serveur se met '
          'en veille quand personne ne l’utilise) ou modifié à tout moment. '
          'Les messages n’étant pas conservés, rien ne peut être récupéré '
          'après une conversation. Dans les limites permises par la loi, '
          'l’éditeur n’est pas responsable des contenus échangés entre '
          'utilisateurs ni des dommages liés à l’utilisation du service.',
    ]),
    LegalSection('Modification des conditions', [
      'Ces conditions peuvent évoluer. Après une modification importante, '
          'l’application vous demandera de les accepter à nouveau.',
    ]),
    LegalSection('Droit applicable', [
      'Les présentes conditions sont soumises au droit français. En cas de '
          'litige, une solution amiable sera recherchée avant toute action ; à '
          'défaut, les tribunaux français sont compétents, sous réserve des '
          'règles impératives protégeant les consommateurs.',
      'Contact : $kLegalContact.',
    ]),
  ],
);

/// In the order shown in "À propos".
const legalDocuments = [legalNotice, privacyPolicy, termsOfUse];
