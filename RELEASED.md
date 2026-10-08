# Notes de version

Les nouveautés de chaque version de Dismessage, la plus récente en premier.

---

## 0.2.0 — 8 octobre 2026

Une version centrée sur la sécurité et la vie privée, en vue de l'ouverture au public.

### ⚠️ À lire avant de mettre à jour

- **Mise à jour obligatoire.** Les anciennes versions ne peuvent plus se connecter : elles affichent « installez la nouvelle version ».
- **Android : désinstallez d'abord l'ancienne version.** L'application est désormais signée avec sa clé définitive, et Android refuse de l'installer par-dessus l'ancienne. Vos contacts enregistrés sur le téléphone seront perdus.
- **Votre ID peut changer.** Les IDs sont maintenant attribués par le serveur. Sauf période de transition décidée par l'éditeur, chaque installation reçoit un nouvel ID à sa première connexion : partagez-le à nouveau avec vos contacts.

### Nouveautés

- **Chiffrement de bout en bout.** Tout le contenu des conversations (texte, frappe en direct, réactions, photos, vocaux, fichiers) est chiffré sur votre appareil. Le serveur ne transmet plus que des données illisibles, et refuse tout ce qui n'est pas chiffré. Les clés sont créées pour chaque conversation, puis oubliées.
- **Code de sécurité.** Menu ⋮ d'une conversation → « Vérifier le chiffrement » : comparez le code avec votre interlocuteur pour vous assurer que personne ne s'est interposé.
- **Bloquer quelqu'un**, depuis sa demande de conversation, depuis un contact ou depuis la conversation. Ses demandes sont ensuite ignorées, sans qu'il le sache.
- **« Seuls mes contacts peuvent me joindre »** : les demandes des inconnus sont ignorées, sans notification.
- **Réglages sur toutes les plateformes** : options de confidentialité et liste des IDs bloqués, avec « Débloquer ».
- **À propos** : version, lien vers le code source sur GitHub, licences des composants, mentions légales.
- **Pages légales** : mentions légales, politique de confidentialité et conditions d'utilisation, dans l'application et sur le web.
- **Accueil au premier lancement** : confirmation de l'âge (18 ans et plus) et acceptation des conditions, avant toute connexion au serveur.

### Sécurité et vie privée

- **Captures d'écran bloquées** sur Android et Windows : captures, enregistrements d'écran, partage d'écran et miniature des applications récentes ne montrent plus les conversations.
- **IDs protégés contre le vol.** Le serveur choisit et signe chaque ID : personne ne peut s'approprier celui d'un autre, même après un redémarrage du serveur.
- **Protection contre les abus** : limites de demandes de conversation, d'enregistrements, de nouveaux IDs et de connexions par adresse. Un usage normal ne les atteint jamais ; un transfert de fichier très rapide est seulement ralenti.
- **Version web** : le moteur d'affichage est servi par le site lui-même, et non plus par les serveurs de Google.

### Améliorations

- Sur un petit téléphone, les boutons de l'en-tête sont regroupés dans un menu ⋮.
- Un ID différent par serveur, retrouvé quand on revient au serveur précédent.
- Les refus du serveur (limite atteinte, version trop ancienne) sont expliqués à l'écran.

---

## 0.1.0 — 6 octobre 2026

Première version.

### Messagerie en direct

- Voir son interlocuteur écrire **caractère par caractère**, avec les trois points `…` quand il fait une pause.
- **ID à 9 chiffres** pour se joindre (`482 913 075`), masqué à l'écran (`482 *** 075`) avec un bouton pour l'afficher.
- **Demandes de conversation** à accepter ou refuser, **contacts** enregistrés sur l'appareil, **présence** en ligne / hors ligne.
- **Plusieurs conversations à la fois**, avec avatars flottants sur téléphone et barre latérale sur grand écran.
- Réponses (glisser une bulle), réactions, émojis, saisie multiligne.

### Médias

- **Photos** (appareil photo, galerie, webcam sur PC) : une miniature floutée part d'abord, l'image nette n'est transférée que si le destinataire l'ouvre. Position GPS supprimée.
- **Messages vocaux**.
- **Fichiers** jusqu'à 512 Mo, acceptés ou refusés par le destinataire, enregistrés dans ses téléchargements.

### Partout

- Applications **Android**, **Windows** (installateur, lancement au démarrage) et **web**.
- **Notifications** des messages, de la frappe et des demandes, avec réponse directe depuis la notification (Android, Windows).
- **Arrière-plan Android** : rester joignable écran éteint, dès le démarrage du téléphone.
- Messages **éphémères** : rien n'est enregistré, ni sur le serveur ni sur l'appareil.
