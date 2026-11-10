defmodule Nebu.Web.PageText do
  @moduledoc """
  The ONE string catalog of the standalone Nebu pages (story oauth-pages-redesign/02): key ->
  `{english, german}`. Pages reference keys, never literals. German uses the formal "Sie".

  A key without a non-empty text in BOTH languages fails the build (checked while this module
  compiles); looking up an unknown key raises `ArgumentError` instead of rendering a blank
  (`fetch!/2`). Texts are plain text: the renderer HTML-escapes them.
  """

  @contact {"If this keeps happening, contact your administrator.",
            "Wenn das häufiger vorkommt, wenden Sie sich an Ihre Administration."}

  @close_restart {"Close this window. Start signing in again from your app.",
                  "Schließen Sie dieses Fenster. Starten Sie die Anmeldung in Ihrer App erneut."}

  @catalog %{
    # ── shell / shared ──
    "ui.more_options" => {"More options", "Weitere Möglichkeiten"},
    "act.contact" => @contact,
    "err.host.prefix" => {"The app says it belongs to", "Die App gibt an, zu folgender Website zu gehören:"},
    "err.host.suffix" =>
      {"(unverified: this server has not checked this claim)", "(ungeprüft: Dieser Server hat diese Angabe nicht überprüft)"},

    # ── error pages: title, heading, explanation, primary suggestion (bold) ──
    "err.unknown_client.title" => {"Unknown app - sign-in not possible", "Unbekannte App - Anmeldung nicht möglich"},
    "err.unknown_client.heading" => {"This app is not known to this server", "Diese App ist diesem Server nicht bekannt"},
    "err.unknown_client.explanation" =>
      {"The app that sent you here is not registered on this server, so you cannot sign in with it.",
       "Die App, von der Sie kommen, ist auf diesem Server nicht registriert. Sie können sich damit nicht anmelden."},
    "err.unknown_client.primary" =>
      {"Check that you opened the right app.", "Prüfen Sie, ob Sie die richtige App geöffnet haben."},
    "err.invalid_redirect_uri.title" =>
      {"Invalid sign-in request - wrong return address", "Ungültige Anmeldeanfrage - falsche Rückkehradresse"},
    "err.invalid_redirect_uri.heading" => {"This sign-in request is not valid", "Diese Anmeldeanfrage ist ungültig"},
    "err.invalid_redirect_uri.explanation" =>
      {"The app asked to send you back to an address that is not registered for it. For your safety you are not sent there.",
       "Die App wollte Sie an eine Adresse zurückschicken, die für sie nicht registriert ist. Zu Ihrer Sicherheit werden Sie nicht dorthin weitergeleitet."},
    "err.invalid_redirect_uri.primary" =>
      {"Close this page and start signing in again from your app.",
       "Schließen Sie diese Seite und starten Sie die Anmeldung in Ihrer App erneut."},
    "err.invalid_request.title" => {"Invalid sign-in request", "Ungültige Anmeldeanfrage"},
    "err.invalid_request.heading" => {"This sign-in request is not valid", "Diese Anmeldeanfrage ist ungültig"},
    "err.invalid_request.explanation" =>
      {"The sign-in request from your app is incomplete or malformed.",
       "Die Anmeldeanfrage Ihrer App ist unvollständig oder fehlerhaft."},
    "err.invalid_request.primary" => @close_restart,
    "err.client_pending.title" =>
      {"App waiting for approval - sign-in not yet possible", "App wartet auf Freigabe - Anmeldung noch nicht möglich"},
    "err.client_pending.heading" => {"This app is waiting for approval", "Diese App wartet auf Freigabe"},
    "err.client_pending.explanation" =>
      {"Your administrator has not yet approved this app for this server. You can sign in once it has been approved.",
       "Ihre Administration hat diese App für diesen Server noch nicht freigegeben. Sobald sie freigegeben ist, können Sie sich anmelden."},
    "err.client_pending.primary" =>
      {"Ask your administrator to review and approve the app.",
       "Bitten Sie Ihre Administration, die App zu prüfen und freizugeben."},
    "err.client_pending.more" => {"Try again later.", "Versuchen Sie es später erneut."},
    "err.client_rejected.title" =>
      {"App not approved - sign-in not possible", "App nicht freigegeben - Anmeldung nicht möglich"},
    "err.client_rejected.heading" => {"This app is not approved", "Diese App ist nicht freigegeben"},
    "err.client_rejected.explanation" =>
      {"Your administrator has not approved this app for this server, so you cannot sign in with it.",
       "Ihre Administration hat diese App für diesen Server nicht freigegeben. Sie können sich damit nicht anmelden."},
    "err.client_rejected.primary" =>
      {"Use another app that is approved for this server.",
       "Verwenden Sie eine andere App, die für diesen Server freigegeben ist."},
    "err.client_rejected.more" =>
      {"Contact your administrator if you think this is a mistake.",
       "Wenden Sie sich an Ihre Administration, falls Sie das für einen Fehler halten."},
    "err.invalid_state.title" =>
      {"Sign-in link expired or already used", "Anmeldelink abgelaufen oder bereits verwendet"},
    "err.invalid_state.heading" =>
      {"This sign-in link cannot be used", "Dieser Anmeldelink kann nicht verwendet werden"},
    "err.invalid_state.explanation" =>
      {"This sign-in link has expired or was already used.",
       "Dieser Anmeldelink ist abgelaufen oder wurde bereits verwendet."},
    "err.invalid_state.primary" => @close_restart,
    "err.device_in_use.title" =>
      {"Sign-in refused - session already in use", "Anmeldung abgelehnt - Sitzung bereits in Verwendung"},
    "err.device_in_use.heading" => {"This sign-in was refused", "Diese Anmeldung wurde abgelehnt"},
    "err.device_in_use.explanation" =>
      {"This app asked to take over a session that another app is using. This is not allowed.",
       "Diese App wollte eine Sitzung übernehmen, die eine andere App verwendet. Das ist nicht erlaubt."},
    "err.device_in_use.primary" => @close_restart,
    "err.device_in_use.more" =>
      {"To use this app on this device, first sign out of the other app that uses it, then start again.",
       "Um diese App auf diesem Gerät zu verwenden, melden Sie sich zuerst in der anderen App ab, die es verwendet, und beginnen Sie dann erneut."},
    "err.forbidden.title" => {"Request refused", "Anfrage abgelehnt"},
    "err.forbidden.heading" => {"This request was refused", "Diese Anfrage wurde abgelehnt"},
    "err.forbidden.explanation" =>
      {"The request did not come from the sign-in page, or the page was open too long. Nothing was changed.",
       "Die Anfrage kam nicht von der Anmeldeseite, oder die Seite war zu lange geöffnet. Es wurde nichts geändert."},
    "err.forbidden.primary" => @close_restart,
    "err.not_found.title" => {"Page not found", "Seite nicht gefunden"},
    "err.not_found.heading" => {"This page does not exist", "Diese Seite existiert nicht"},
    "err.not_found.explanation" =>
      {"There is nothing at this address.", "Unter dieser Adresse gibt es nichts."},
    "err.not_found.primary" => @close_restart,
    "err.unavailable.title" =>
      {"Sign-in temporarily unavailable", "Anmeldung vorübergehend nicht verfügbar"},
    "err.unavailable.heading" =>
      {"Sign-in is not available right now", "Die Anmeldung ist im Moment nicht verfügbar"},
    "err.unavailable.explanation" =>
      {"This server cannot complete the sign-in at the moment.",
       "Dieser Server kann die Anmeldung im Moment nicht abschließen."},
    "err.unavailable.primary" =>
      {"Try again in a few minutes.", "Versuchen Sie es in einigen Minuten erneut."},
    "err.rate_limited.title" => {"Too many sign-in attempts", "Zu viele Anmeldeversuche"},
    "err.rate_limited.heading" => {"Too many sign-in attempts", "Zu viele Anmeldeversuche"},
    "err.rate_limited.explanation" =>
      {"There were too many sign-in attempts from your network in a short time.",
       "Aus Ihrem Netzwerk gab es in kurzer Zeit zu viele Anmeldeversuche."},
    "err.rate_limited.primary" =>
      {"Wait a little while, then start signing in again from your app.",
       "Warten Sie einen Moment und starten Sie die Anmeldung in Ihrer App dann erneut."},
    "err.method_not_allowed.title" =>
      {"This page cannot be opened this way", "Diese Seite kann so nicht geöffnet werden"},
    "err.method_not_allowed.heading" =>
      {"This page cannot be opened this way", "Diese Seite kann so nicht geöffnet werden"},
    "err.method_not_allowed.explanation" =>
      {"This address only works when your app sends you here.",
       "Diese Adresse funktioniert nur, wenn Ihre App Sie hierher schickt."},
    "err.method_not_allowed.primary" =>
      {"Start signing in from your app.", "Starten Sie die Anmeldung in Ihrer App."},
    "err.server_error.title" => {"Sign-in failed - server error", "Anmeldung fehlgeschlagen - Serverfehler"},
    "err.server_error.heading" => {"Something went wrong", "Etwas ist schiefgelaufen"},
    "err.server_error.explanation" =>
      {"The server ran into an unexpected problem while signing you in.",
       "Beim Anmelden ist auf dem Server ein unerwartetes Problem aufgetreten."},
    "err.server_error.primary" => @close_restart,

    # ── consent page (story oauth-pages-redesign/03). `{name}` placeholders are filled by the page with safe HTML. ──
    "consent.title" => {"Allow this app to use your account", "Dieser App Zugriff auf Ihr Konto erlauben"},
    "consent.heading" => {"Allow this app to use your account?", "Dieser App Zugriff auf Ihr Konto erlauben?"},
    "consent.claim" =>
      {"Name given by the app, not verified", "Vom Hersteller der App angegeben, nicht geprüft"},
    "consent.no_name" => {"No name given", "Kein Name angegeben"},
    "consent.none_given" => {"None given", "Keine Angabe"},
    "consent.perm.as" => {"As", "Als"},
    "consent.perm.gets" => {"it gets", "erhält sie"},
    "consent.perm.full" => {"full access", "vollen Zugriff"},
    "consent.perm.rest" =>
      {": read and send messages, manage rooms, devices and encryption keys.",
       ": Nachrichten lesen und senden, Räume, Geräte und Verschlüsselungsschlüssel verwalten."},
    "consent.devname" => {"This session will be named", "Diese Sitzung heißt"},
    "consent.allow" => {"Allow", "Erlauben"},
    "consent.deny" => {"Deny", "Ablehnen"},
    "consent.arm_hint" =>
      {"Allow unlocks a moment after you interact with this page. This protects you from accidental clicks.",
       "Erlauben wird kurz nach Ihrer ersten Interaktion mit dieser Seite freigeschaltet. Das schützt vor versehentlichen Klicks."},
    "consent.arm_instructions" =>
      {"Mouse: move the pointer onto Allow, then click. Keyboard: move the focus onto Allow, then press Enter. Touch: tap Allow. Allow becomes available a moment after your first interaction with the page.",
       "Maus: Bewegen Sie den Zeiger auf Erlauben und klicken Sie dann. Tastatur: Setzen Sie den Fokus auf Erlauben und drücken Sie dann die Eingabetaste. Touch: Tippen Sie auf Erlauben. Erlauben wird kurz nach Ihrer ersten Interaktion mit der Seite verfügbar."},
    "consent.noscript" =>
      {"JavaScript is off, so Allow stays unavailable. Turn on JavaScript or use another browser. You can still choose Deny.",
       "JavaScript ist aus, daher bleibt Erlauben gesperrt. Schalten Sie JavaScript ein oder verwenden Sie einen anderen Browser. Ablehnen funktioniert weiterhin."},
    "consent.fine" =>
      {"Only allow this if you just started signing in to this app yourself.",
       "Erlauben Sie nur, wenn Sie die Anmeldung in dieser App gerade selbst gestartet haben."},
    "consent.details" => {"Show details", "Details anzeigen"},
    "consent.warning" => {"Warning:", "Achtung:"},
    "consent.headsup" => {"Heads-up:", "Hinweis:"},
    "consent.fresh.text" =>
      {"You were not asked for your password just now. Your sign-in provider did not confirm a new sign-in for this request. If you did not just start signing in to this app yourself, choose Deny.",
       "Ihr Passwort wurde eben nicht abgefragt. Ihr Anmeldedienst hat für diese Anfrage keine neue Anmeldung bestätigt. Wenn Sie die Anmeldung in dieser App nicht gerade selbst gestartet haben, wählen Sie Ablehnen."},
    "consent.dest.text" =>
      {"You are sent to {host}, which does not belong to the website this app names ({site}). Only continue if you trust it.",
       "Sie werden zu {host} weitergeleitet. Das gehört nicht zur Website, die diese App angibt ({site}). Fahren Sie nur fort, wenn Sie dem vertrauen."},
    "consent.replace.text" =>
      {"Another session will be signed out: {name} (device {id}).",
       "Eine andere Sitzung wird abgemeldet: {name} (Gerät {id})."},
    "consent.name_label" => {"Device name", "Gerätename"},
    "consent.name_hint" =>
      {"The app gave Nebu no usable name. The name helps you tell your devices apart. Use the Allow button when you are done; the Enter key denies.",
       "Die App hat Nebu keinen brauchbaren Namen genannt. Der Name hilft Ihnen, Ihre Geräte auseinanderzuhalten. Verwenden Sie danach die Schaltfläche Erlauben; die Eingabetaste lehnt ab."},
    "consent.name_error.label" => {"Name needed:", "Name erforderlich:"},
    "consent.name_error.text" =>
      {"Type a name for this device, then choose Allow.", "Geben Sie diesem Gerät einen Namen und wählen Sie dann Erlauben."},
    "consent.d.website" =>
      {"App website (claimed by the app, not verified by Nebu)",
       "Website der App (von der App angegeben, nicht von Nebu geprüft)"},
    "consent.d.destination" => {"After you choose, you are sent to", "Nach Ihrer Wahl werden Sie weitergeleitet zu"},
    "consent.d.session" => {"Your session", "Ihre Sitzung"},
    "consent.d.terms" => {"Terms of service (claimed by the app)", "Nutzungsbedingungen (von der App angegeben)"},
    "consent.d.privacy" => {"Privacy policy (claimed by the app)", "Datenschutzerklärung (von der App angegeben)"},
    "consent.dest.part" => {"(part of the app website)", "(Teil der App-Website)"},
    "consent.dest.port" => {"{host}, port {port}", "{host}, Port {port}"},
    "consent.dest.local" =>
      {"an app on this device ({detail}). Nebu cannot check which app on your device receives this.",
       "eine App auf diesem Gerät ({detail}). Nebu kann nicht prüfen, welche App auf Ihrem Gerät dies erhält."},
    "consent.session.new" =>
      {"A new session (device {id}) will be created.", "Eine neue Sitzung (Gerät {id}) wird angelegt."},
    "consent.session.same" =>
      {"Continues your existing session {name} (device {id}), last active {when}.",
       "Setzt Ihre bestehende Sitzung {name} (Gerät {id}) fort, zuletzt aktiv {when}."},
    "consent.session.replace" =>
      {"Replaces your existing session {name} (device {id}), last active {when}, signed in without this app. That session will be signed out.",
       "Ersetzt Ihre bestehende Sitzung {name} (Gerät {id}), zuletzt aktiv {when}, ohne diese App angemeldet. Diese Sitzung wird abgemeldet."},
    "consent.unnamed_device" => {"Unnamed device", "Unbenanntes Gerät"},
    "consent.unknown_time" => {"at an unknown time", "zu einem unbekannten Zeitpunkt"},

    # ── legacy SSO confirm page (story oauth-pages-redesign/04) ──
    "sso.confirm.title" => {"Confirm sign-in", "Anmeldung bestätigen"},
    "sso.confirm.heading" => {"Continue signing in to this app?", "Mit der Anmeldung bei dieser App fortfahren?"},
    "sso.confirm.origin_label" => {"The app asks to be sent to", "Die App möchte Sie weiterleiten zu"},
    "sso.confirm.notice" =>
      {"This address is not on the list of apps your administrator trusts. Continuing gives the app at this address full access to your Matrix account: it can read and send messages as you. Only continue if you just started signing in to this app yourself and you recognise the address. Cancel stops the sign-in and sends nothing to the app. This request expires in 5 minutes.",
       "Diese Adresse steht nicht auf der Liste der Apps, denen Ihre Administration vertraut. Wenn Sie fortfahren, erhält die App unter dieser Adresse vollen Zugriff auf Ihr Matrix-Konto: Sie kann in Ihrem Namen Nachrichten lesen und senden. Fahren Sie nur fort, wenn Sie die Anmeldung in dieser App gerade selbst gestartet haben und die Adresse kennen. Mit Abbrechen wird die Anmeldung beendet und nichts an die App gesendet. Diese Anfrage läuft in 5 Minuten ab."},
    "sso.confirm.cancel" => {"Cancel", "Abbrechen"},
    "sso.confirm.continue" => {"Continue", "Fortfahren"},
    "sso.confirm.arm_hint" =>
      {"Continue becomes available a moment after you interact with this page. Then move onto Continue to use it.",
       "Fortfahren wird kurz nach Ihrer ersten Interaktion mit dieser Seite verfügbar. Gehen Sie dann zu Fortfahren, um es zu verwenden."},
    "sso.confirm.noscript" =>
      {"JavaScript is off, so Continue stays unavailable. Turn on JavaScript or use another browser. You can still choose Cancel.",
       "JavaScript ist aus, daher bleibt Fortfahren gesperrt. Schalten Sie JavaScript ein oder verwenden Sie einen anderen Browser. Abbrechen funktioniert weiterhin."},
    "sso.confirm.d.user" => {"Signed in as", "Angemeldet als"},
    "sso.confirm.d.path" => {"Path", "Pfad"},
    "sso.confirm.idn" =>
      {"This address uses special characters, which can be used to imitate another address. It is shown in a technical form starting with xn--. Check it carefully.",
       "Diese Adresse enthält Sonderzeichen, mit denen sich eine andere Adresse vortäuschen lässt. Sie wird in technischer Form mit xn-- am Anfang angezeigt. Prüfen Sie sie sorgfältig."},
    "sso.cancelled.title" => {"Sign-in cancelled", "Anmeldung abgebrochen"},
    "sso.cancelled.text" =>
      {"No access was given. You can close this window.", "Es wurde kein Zugriff gewährt. Sie können dieses Fenster schließen."},
    "sso.more.back_to_app" =>
      {"Go back to the app you were signing in to.", "Gehen Sie zurück zu der App, bei der Sie sich anmelden wollten."},
    "sso.more.use_buttons" =>
      {"Go back to the confirmation page and use its buttons.",
       "Gehen Sie zurück zur Bestätigungsseite und verwenden Sie deren Schaltflächen."},

    # ── UIA SSO fallback result pages and the unsupported-login page (story oauth-pages-redesign/04) ──
    "uia.complete.title" => {"Authentication complete", "Authentifizierung abgeschlossen"},
    "uia.complete.text" =>
      {"You may return to your client.", "Sie können jetzt zu Ihrer App zurückkehren."},
    "uia.mismatch.title" => {"Authentication did not match", "Authentifizierung stimmt nicht überein"},
    "uia.mismatch.heading" =>
      {"This sign-in does not match the request", "Diese Anmeldung passt nicht zur Anfrage"},
    "uia.mismatch.explanation" =>
      {"The sign-in did not match the request that started it. Nothing was authorised.",
       "Die Anmeldung passt nicht zu der Anfrage, die sie ausgelöst hat. Es wurde nichts autorisiert."},
    "uia.mismatch.primary" =>
      {"Close this window and try again from your app.",
       "Schließen Sie dieses Fenster und versuchen Sie es in Ihrer App erneut."},
    "unsupported.title" => {"Sign-in method not supported", "Anmeldemethode nicht unterstützt"},
    "unsupported.heading" =>
      {"This app's sign-in method is not supported", "Die Anmeldemethode dieser App wird nicht unterstützt"},
    "unsupported.explanation" =>
      {"The sign-in method of this app ({scheme}) is not permitted on this server yet.",
       "Die Anmeldemethode dieser App ({scheme}) ist auf diesem Server noch nicht erlaubt."},
    "unsupported.primary" =>
      {"Contact your administrator and ask them to allow this method.",
       "Wenden Sie sich an Ihre Administration und bitten Sie sie, diese Methode zu erlauben."},
    "unsupported.more" =>
      {"Administrators: add the scheme at /admin/config, in the section SSO redirect schemes.",
       "Administration: Tragen Sie das Schema unter /admin/config im Abschnitt SSO redirect schemes ein."},
    # ── account portal /account (story oauth-pages-redesign/05). `{name}` placeholders are filled by the page with safe HTML. ──
    "acct.nav.label" => {"Account", "Konto"},
    "acct.nav.overview" => {"Overview", "Übersicht"},
    "acct.nav.devices" => {"Devices", "Geräte"},
    "acct.nav.apps" => {"Apps", "Apps"},
    "acct.nav.security" => {"Security", "Sicherheit"},
    "acct.signed_in_as" => {"Signed in as", "Angemeldet als"},
    "acct.logout" => {"Sign out of this page", "Von dieser Seite abmelden"},
    "acct.unknown" => {"Unknown", "Unbekannt"},
    "acct.never" => {"Never", "Nie"},
    "acct.not_set" => {"Not set", "Nicht gesetzt"},
    "acct.details" => {"Details", "Details"},
    "acct.label.done" => {"Done:", "Erledigt:"},
    "acct.label.problem" => {"Problem:", "Problem:"},
    "acct.label.note" => {"Note:", "Hinweis:"},

    # overview and profile
    "acct.default.title" => {"Your account", "Ihr Konto"},
    "acct.default.heading" => {"Your account", "Ihr Konto"},
    "acct.default.sentence" =>
      {"Manage where you are signed in and which apps may use your account.",
       "Verwalten Sie, wo Sie angemeldet sind und welche Apps Ihr Konto nutzen dürfen."},
    "acct.tile.devices_count" => {"{n} signed in", "{n} angemeldet"},
    "acct.tile.devices_count_least" => {"At least {n} signed in", "Mindestens {n} angemeldet"},
    "acct.tile.apps_count" => {"{n} allowed", "{n} erlaubt"},
    "acct.tile.apps_open" => {"Manage allowed apps", "Erlaubte Apps verwalten"},
    "acct.tile.security" => {"Reset encryption identity", "Verschlüsselungs-Identität zurücksetzen"},
    "acct.profile.title" => {"Your profile", "Ihr Profil"},
    "acct.profile.heading" => {"Your profile", "Ihr Profil"},
    "acct.profile.summary" => {"Show profile details", "Profildetails anzeigen"},
    "acct.profile.matrix_id" => {"Matrix ID", "Matrix ID"},
    "acct.profile.display_name" => {"Display name", "Anzeigename"},
    "acct.profile.note" =>
      {"You change your display name in your Matrix app. Deactivating your account and changing your password are managed by your administrator and your company account.",
       "Ihren Anzeigenamen ändern Sie in Ihrer Matrix-App. Das Deaktivieren Ihres Kontos und das Ändern Ihres Passworts verwaltet Ihre Administration über Ihr Firmenkonto."},

    # devices
    "acct.devices.title" => {"Your devices", "Ihre Geräte"},
    "acct.devices.heading" => {"Your devices", "Ihre Geräte"},
    "acct.devices.sentence" =>
      {"These devices are signed in to your account. Do you not recognise one? Sign it out.",
       "Diese Geräte sind bei Ihrem Konto angemeldet. Ein Gerät kommt Ihnen unbekannt vor? Melden Sie es ab."},
    "acct.devices.empty" =>
      {"There are no devices on your account yet.", "Auf Ihrem Konto gibt es noch keine Geräte."},
    "acct.devices.more.exact.one" => {"{n} more device not shown.", "{n} weiteres Gerät nicht angezeigt."},
    "acct.devices.more.exact.other" => {"{n} more devices not shown.", "{n} weitere Geräte nicht angezeigt."},
    "acct.devices.more.least.one" =>
      {"At least {n} more device not shown.", "Mindestens {n} weiteres Gerät nicht angezeigt."},
    "acct.devices.more.least.other" =>
      {"At least {n} more devices not shown.", "Mindestens {n} weitere Geräte nicht angezeigt."},
    "acct.device.sign_out" => {"Sign out", "Abmelden"},
    "acct.device.sign_out_label" => {"Sign out {name} ({id})", "{name} abmelden ({id})"},
    "acct.device.d.id" => {"Device ID", "Geräte-ID"},
    "acct.device.d.name" => {"Name", "Name"},
    "acct.device.d.app" =>
      {"App (name given by the app, not verified)", "App (von der App angegeben, nicht geprüft)"},
    "acct.device.d.ip" => {"Last IP", "Letzte IP-Adresse"},
    "acct.device.d.last_active" => {"Last active", "Zuletzt aktiv"},
    "acct.device.d.added" => {"Added", "Hinzugefügt"},
    "acct.active.never" => {"never active", "noch nie aktiv"},
    "acct.active.rel" => {"active {ago}", "zuletzt aktiv {ago}"},
    "acct.active.date" => {"active on {date}", "zuletzt aktiv am {date}"},
    "acct.app.unnamed" => {"Unnamed app", "Unbenannte App"},
    "acct.app.legacy" => {"Matrix app (company sign-in)", "Matrix-App (Firmen-Anmeldung)"},
    "acct.app.none" => {"Not signed in", "Nicht angemeldet"},

    # one device and the sign-out confirmation
    "acct.device.title" => {"Device details", "Gerätedetails"},
    "acct.device.heading" => {"Device details", "Gerätedetails"},
    "acct.device.sign_out_this" => {"Sign out this device", "Dieses Gerät abmelden"},
    "acct.device.sign_out_this_label" =>
      {"Sign out this device: {name} ({id})", "Dieses Gerät abmelden: {name} ({id})"},
    "acct.device.back" => {"Back to all devices", "Zurück zu allen Geräten"},
    "acct.delete.title" => {"Sign out {name}?", "{name} abmelden?"},
    "acct.delete.confirm" => {"Sign out {name}", "{name} abmelden"},
    "acct.delete.explain" =>
      {"The app on this device will be signed out and the encryption keys stored for this device will be deleted. You can sign in again from the app at any time.",
       "Die App auf diesem Gerät wird abgemeldet und die für dieses Gerät gespeicherten Verschlüsselungsschlüssel werden gelöscht. Sie können sich jederzeit erneut in der App anmelden."},
    "acct.delete.reauth" =>
      {"For your safety, confirm that it is you again with your company sign-in before you sign out a device.",
       "Bestätigen Sie zu Ihrer Sicherheit erneut mit Ihrer Firmen-Anmeldung, dass Sie es sind, bevor Sie ein Gerät abmelden."},
    "acct.delete.cancel" =>
      {"Cancel - keep this device signed in", "Abbrechen - Gerät angemeldet lassen"},
    # rename a device (story oauth-pages-redesign/06)
    "acct.device.rename" => {"Rename", "Umbenennen"},
    "acct.device.rename_label" => {"Rename {name} ({id})", "{name} umbenennen ({id})"},
    "acct.rename.title" => {"Rename this device", "Dieses Gerät umbenennen"},
    "acct.rename.heading" => {"Rename this device", "Dieses Gerät umbenennen"},
    "acct.rename.label" => {"Device name", "Gerätename"},
    "acct.rename.hint" =>
      {"A name you will recognise, for example \"Anna's phone\". At most 64 characters.",
       "Ein Name, den Sie wiedererkennen, zum Beispiel \"Annas Handy\". Höchstens 64 Zeichen."},
    "acct.rename.save" => {"Save", "Speichern"},
    "acct.rename.cancel" => {"Cancel", "Abbrechen"},
    "acct.rename.reauth" =>
      {"For your safety, confirm that it is you again with your company sign-in before you change the name of a device.",
       "Bestätigen Sie zu Ihrer Sicherheit erneut mit Ihrer Firmen-Anmeldung, dass Sie es sind, bevor Sie den Namen eines Geräts ändern."},
    "acct.reauth.button" => {"Confirm that it is you", "Bestätigen, dass Sie es sind"},

    # apps
    "acct.apps.title" => {"Apps you have allowed", "Erlaubte Apps"},
    "acct.apps.heading" => {"Apps you have allowed", "Erlaubte Apps"},
    "acct.apps.note" =>
      {"These apps may use your account without asking you again.",
       "Diese Apps dürfen Ihr Konto nutzen, ohne dass Sie erneut gefragt werden."},
    "acct.apps.details_summary" => {"More about allowed apps", "Mehr zu erlaubten Apps"},
    "acct.apps.details" =>
      {"These are the apps you have allowed to use your Matrix account. Nebu does not ask you again for them. Withdrawing the permission of an app does not sign out devices that are already signed in: use the Devices page for that. The app asks for your permission again the next time it wants to sign you in.",
       "Das sind die Apps, denen Sie erlaubt haben, Ihr Matrix-Konto zu nutzen. Nebu fragt Sie für diese Apps nicht erneut. Wenn Sie die Berechtigung einer App widerrufen, werden bereits angemeldete Geräte nicht abgemeldet: Dafür gibt es die Seite Geräte. Die App fragt beim nächsten Anmelden erneut nach Ihrer Erlaubnis."},
    "acct.apps.empty" =>
      {"There are no allowed apps on your account. An app appears here after you allow it when you sign in.",
       "Auf Ihrem Konto gibt es keine erlaubten Apps. Eine App erscheint hier, nachdem Sie sie bei der Anmeldung erlaubt haben."},
    "acct.apps.website" => {"Website", "Website"},
    "acct.apps.allowed_on" => {"Allowed on", "Erlaubt am"},
    "acct.apps.host_unknown" => {"unknown website", "unbekannte Website"},
    "acct.apps.withdraw" => {"Withdraw", "Widerrufen"},
    "acct.apps.withdraw_label" =>
      {"Withdraw the permission of {name} ({host})", "Berechtigung von {name} ({host}) widerrufen"},

    # encryption reset
    "acct.reset.title" => {"Reset your encryption identity", "Verschlüsselungs-Identität zurücksetzen"},
    "acct.reset.heading" => {"Reset your encryption identity", "Verschlüsselungs-Identität zurücksetzen"},
    "acct.reset.intro" =>
      {"When an app asks to reset your encryption identity (your cross-signing keys), you approve or decline the request here. Approve only if you started that reset yourself, just now.",
       "Wenn eine App anfragt, Ihre Verschlüsselungs-Identität (Ihre Cross-Signing-Schlüssel) zurückzusetzen, genehmigen oder lehnen Sie die Anfrage hier ab. Genehmigen Sie nur, wenn Sie diese Zurücksetzung gerade selbst gestartet haben."},
    "acct.reset.none" =>
      {"There is no pending request. Start the reset in your app first, then come back.",
       "Es liegt keine Anfrage vor. Starten Sie die Zurücksetzung zuerst in Ihrer App und kommen Sie dann zurück."},
    "acct.reset.reauth" =>
      {"For your safety, confirm that it is you again with your company sign-in before you approve or decline a request.",
       "Bestätigen Sie zu Ihrer Sicherheit erneut mit Ihrer Firmen-Anmeldung, dass Sie es sind, bevor Sie eine Anfrage genehmigen oder ablehnen."},
    "acct.reset.several" =>
      {"{n} reset requests are waiting. You started at most one of them. Decline every request you do not recognise; you can approve once only one is left.",
       "{n} Zurücksetzungs-Anfragen warten. Höchstens eine davon haben Sie selbst gestartet. Lehnen Sie jede Anfrage ab, die Sie nicht kennen; genehmigen können Sie erst, wenn nur noch eine übrig ist."},
    "acct.reset.request_from" => {"Request from {device}", "Anfrage von {device}"},
    "acct.reset.d.app" => {"App (name chosen by the app)", "App (von der App gewählt)"},
    "acct.reset.d.last_active" => {"Device last active", "Gerät zuletzt aktiv"},
    "acct.reset.d.requested" => {"Requested", "Angefragt"},
    "acct.reset.d.expires" => {"Expires", "Läuft ab"},
    "acct.reset.d.reference" => {"Request reference", "Anfragereferenz"},
    "acct.reset.warn" =>
      {"Only approve if you started resetting your identity in that app just now. Your other devices and your contacts will have to verify you again.",
       "Genehmigen Sie nur, wenn Sie das Zurücksetzen Ihrer Identität in dieser App gerade selbst gestartet haben. Ihre anderen Geräte und Ihre Kontakte müssen Sie dann erneut verifizieren."},
    "acct.reset.decline_note" =>
      {"If you decline, your current identity stays as it is and the app has to ask again.",
       "Wenn Sie ablehnen, bleibt Ihre aktuelle Identität bestehen und die App muss erneut anfragen."},
    "acct.reset.decline" => {"Decline", "Ablehnen"},
    "acct.reset.decline_label" =>
      {"Decline reset requested by {device}", "Zurücksetzen ablehnen, angefragt von {device}"},
    "acct.reset.approve" => {"Approve reset", "Zurücksetzen genehmigen"},
    "acct.reset.approve_label" =>
      {"Approve reset requested by {device}", "Zurücksetzen genehmigen, angefragt von {device}"},
    "acct.reset.unknown_app" => {"Unknown app", "Unbekannte App"},
    "acct.reset.unknown_device" => {"an unknown device", "ein unbekanntes Gerät"},
    "acct.reset.soon" => {"soon", "bald"},

    # signed out
    "acct.signed_out.title" => {"Signed out", "Abgemeldet"},
    "acct.signed_out.heading" => {"You are signed out", "Sie sind abgemeldet"},
    "acct.signed_out.text" =>
      {"You can close this page, or sign in again. Your company sign-in session may still be active: close the browser or sign out at your company sign-in if you share this computer.",
       "Sie können diese Seite schließen oder sich erneut anmelden. Ihre Firmen-Anmeldung ist möglicherweise noch aktiv: Schließen Sie den Browser oder melden Sie sich bei Ihrer Firmen-Anmeldung ab, wenn Sie diesen Computer mit anderen teilen."},
    "acct.signed_out.again" => {"Sign in again", "Erneut anmelden"},

    # relative time: past and future, minutes / hours / days, singular and plural (`PageText.relative/2`)
    "rel.now" => {"just now", "gerade eben"},
    "rel.past.minute.one" => {"1 minute ago", "vor 1 Minute"},
    "rel.past.minute.other" => {"{n} minutes ago", "vor {n} Minuten"},
    "rel.past.hour.one" => {"1 hour ago", "vor 1 Stunde"},
    "rel.past.hour.other" => {"{n} hours ago", "vor {n} Stunden"},
    "rel.past.day.one" => {"1 day ago", "vor 1 Tag"},
    "rel.past.day.other" => {"{n} days ago", "vor {n} Tagen"},
    "rel.future.minute.one" => {"in 1 minute", "in 1 Minute"},
    "rel.future.minute.other" => {"in {n} minutes", "in {n} Minuten"},
    "rel.future.hour.one" => {"in 1 hour", "in 1 Stunde"},
    "rel.future.hour.other" => {"in {n} hours", "in {n} Stunden"},
    "rel.future.day.one" => {"in 1 day", "in 1 Tag"},
    "rel.future.day.other" => {"in {n} days", "in {n} Tagen"},

    # account notices (after a redirect with ?notice=<code>)
    "acct.notice.device_deleted" => {"The device was signed out.", "Das Gerät wurde abgemeldet."},
    "acct.notice.device_renamed" => {"The device was renamed.", "Das Gerät wurde umbenannt."},
    "acct.notice.device_name_invalid" =>
      {"The name has no visible characters left. Please enter another name. Nothing was changed.",
       "Der Name enthält keine sichtbaren Zeichen. Bitte geben Sie einen anderen Namen ein. Es wurde nichts geändert."},
    "acct.notice.reset_approved" =>
      {"Reset approved. Return to your app and continue.", "Zurücksetzen genehmigt. Kehren Sie zu Ihrer App zurück und machen Sie dort weiter."},
    "acct.notice.reset_declined" => {"Reset declined.", "Zurücksetzen abgelehnt."},
    "acct.notice.signed_out" =>
      {"You have been signed out of the account page.", "Sie wurden von der Kontoseite abgemeldet."},
    "acct.notice.grant_withdrawn" =>
      {"The permission of the app was withdrawn. It asks you again the next time it wants to sign you in. Devices that are already signed in stay signed in.",
       "Die Berechtigung der App wurde widerrufen. Sie fragt beim nächsten Anmelden erneut nach Ihrer Erlaubnis. Bereits angemeldete Geräte bleiben angemeldet."},
    "acct.notice.activation_unproven" =>
      {"Nothing was changed. We could not confirm that you pressed the button yourself. Reload this page and press Approve reset again. If it keeps happening, turn off content blockers for this site or try another browser.",
       "Es wurde nichts geändert. Wir konnten nicht bestätigen, dass Sie die Schaltfläche selbst gedrückt haben. Laden Sie diese Seite neu und drücken Sie erneut auf Zurücksetzen genehmigen. Wenn das weiter passiert, schalten Sie Inhaltsblocker für diese Seite aus oder verwenden Sie einen anderen Browser."},
    "acct.notice.device_not_found" =>
      {"This device was not found. Here are all your devices.", "Dieses Gerät wurde nicht gefunden. Hier sind alle Ihre Geräte."},
    "acct.notice.invalid_request" =>
      {"Part of the link was not understood, so here is the overview.", "Ein Teil des Links wurde nicht verstanden, deshalb sehen Sie hier die Übersicht."},
    "acct.notice.reset_not_found" =>
      {"This reset request was not found or has expired. Nothing was changed.", "Diese Zurücksetzungs-Anfrage wurde nicht gefunden oder ist abgelaufen. Es wurde nichts geändert."},
    "acct.notice.stale" =>
      {"Please confirm that it is you first. Nothing was changed.", "Bitte bestätigen Sie zuerst, dass Sie es sind. Es wurde nichts geändert."},
    "acct.notice.grant_not_found" =>
      {"This app was not found in your list of allowed apps. Nothing was changed.", "Diese App wurde in Ihrer Liste erlaubter Apps nicht gefunden. Es wurde nichts geändert."},
    "acct.notice.freshness_unavailable" =>
      {"Your sign-in provider does not report when you last signed in, so Nebu cannot confirm it is you. Signing out devices and approving key resets are not available here. Ask your administrator.",
       "Ihr Anmeldedienst meldet nicht, wann Sie sich zuletzt angemeldet haben, deshalb kann Nebu nicht bestätigen, dass Sie es sind. Geräte abmelden und Schlüssel-Zurücksetzungen genehmigen ist hier nicht möglich. Wenden Sie sich an Ihre Administration."},

    # account error pages: title, heading, explanation, primary suggestion (bold), further suggestions under "More options"
    "acct.err.restart" => {"Open the account page", "Kontoseite öffnen"},
    "acct.err.unavailable.title" =>
      {"Account page temporarily unavailable", "Kontoseite vorübergehend nicht verfügbar"},
    "acct.err.unavailable.heading" =>
      {"The account page is not available right now", "Die Kontoseite ist im Moment nicht verfügbar"},
    "acct.err.unavailable.explanation" =>
      {"This server cannot show the account page at the moment.", "Dieser Server kann die Kontoseite im Moment nicht anzeigen."},
    "acct.err.unavailable.primary" =>
      {"Try again in a few minutes.", "Versuchen Sie es in einigen Minuten erneut."},
    "acct.err.rate_limited.title" => {"Too many requests", "Zu viele Anfragen"},
    "acct.err.rate_limited.heading" => {"Too many requests", "Zu viele Anfragen"},
    "acct.err.rate_limited.explanation" =>
      {"There were too many requests from your network in a short time.", "Aus Ihrem Netzwerk gab es in kurzer Zeit zu viele Anfragen."},
    "acct.err.rate_limited.primary" =>
      {"Wait a few minutes, then try again.", "Warten Sie ein paar Minuten und versuchen Sie es dann erneut."},
    "acct.err.rate_limited.more" =>
      {"If you are on a shared company network, requests from other people count too.",
       "Wenn Sie in einem gemeinsamen Firmennetzwerk sind, zählen auch Anfragen anderer Personen mit."},
    "acct.err.method_not_allowed.title" =>
      {"This page cannot be opened this way", "Diese Seite kann so nicht geöffnet werden"},
    "acct.err.method_not_allowed.heading" =>
      {"This page cannot be opened this way", "Diese Seite kann so nicht geöffnet werden"},
    "acct.err.method_not_allowed.explanation" =>
      {"This address only works from the account page itself.", "Diese Adresse funktioniert nur von der Kontoseite aus."},
    "acct.err.method_not_allowed.primary" =>
      {"Open the account page from your app or from the link below.",
       "Öffnen Sie die Kontoseite aus Ihrer App oder über den Link unten."},
    "acct.err.not_found.title" => {"Page not found", "Seite nicht gefunden"},
    "acct.err.not_found.heading" => {"This page does not exist", "Diese Seite existiert nicht"},
    "acct.err.not_found.explanation" =>
      {"There is nothing at this address.", "Unter dieser Adresse gibt es nichts."},
    "acct.err.not_found.primary" =>
      {"Open the account page from your app or from the link below.",
       "Öffnen Sie die Kontoseite aus Ihrer App oder über den Link unten."},
    "acct.err.invalid_request.title" => {"Invalid request", "Ungültige Anfrage"},
    "acct.err.invalid_request.heading" => {"This request is not valid", "Diese Anfrage ist ungültig"},
    "acct.err.invalid_request.explanation" =>
      {"The request is incomplete or malformed. Nothing was changed.",
       "Die Anfrage ist unvollständig oder fehlerhaft. Es wurde nichts geändert."},
    "acct.err.invalid_request.primary" =>
      {"Go back to the account page and try again.", "Kehren Sie zur Kontoseite zurück und versuchen Sie es erneut."},
    "acct.err.invalid_state.title" =>
      {"Sign-in link expired or already used", "Anmeldelink abgelaufen oder bereits verwendet"},
    "acct.err.invalid_state.heading" =>
      {"This sign-in link cannot be used", "Dieser Anmeldelink kann nicht verwendet werden"},
    "acct.err.invalid_state.explanation" =>
      {"This sign-in link has expired or was already used.", "Dieser Anmeldelink ist abgelaufen oder wurde bereits verwendet."},
    "acct.err.invalid_state.primary" =>
      {"Open the account page again from your app to start a new sign-in.",
       "Öffnen Sie die Kontoseite erneut aus Ihrer App, um eine neue Anmeldung zu starten."},
    "acct.err.forbidden.title" => {"Request refused", "Anfrage abgelehnt"},
    "acct.err.forbidden.heading" => {"This request was refused", "Diese Anfrage wurde abgelehnt"},
    "acct.err.forbidden.explanation" =>
      {"The request did not come from the account page, or the page was open too long. Nothing was changed.",
       "Die Anfrage kam nicht von der Kontoseite, oder die Seite war zu lange geöffnet. Es wurde nichts geändert."},
    "acct.err.forbidden.primary" =>
      {"Open the account page again from your app and repeat the action there.",
       "Öffnen Sie die Kontoseite erneut aus Ihrer App und wiederholen Sie die Aktion dort."},
    "acct.err.forbidden.more" =>
      {"Approving an encryption reset needs a current Chrome, Firefox or Safari: an old browser, or a proxy that removes the Sec-Fetch headers, is refused.",
       "Zum Genehmigen einer Verschlüsselungs-Zurücksetzung brauchen Sie ein aktuelles Chrome, Firefox oder Safari: Ein alter Browser oder ein Proxy, der die Sec-Fetch-Header entfernt, wird abgewiesen."},
    "acct.err.no_account.title" => {"No account found", "Kein Konto gefunden"},
    "acct.err.no_account.heading" =>
      {"You have no account on this server yet", "Sie haben auf diesem Server noch kein Konto"},
    "acct.err.no_account.explanation" =>
      {"Your company account is not known on this server. Sign in with a Matrix app first.",
       "Ihr Firmenkonto ist auf diesem Server nicht bekannt. Melden Sie sich zuerst mit einer Matrix-App an."},
    "acct.err.no_account.primary" =>
      {"Sign in once with a Matrix app on this server.", "Melden Sie sich einmal mit einer Matrix-App auf diesem Server an."},
    "acct.err.no_account.more" =>
      {"Then open the account page again.", "Öffnen Sie danach die Kontoseite erneut."},
    "acct.err.deactivated.title" => {"Account deactivated", "Konto deaktiviert"},
    "acct.err.deactivated.heading" =>
      {"This account has been deactivated", "Dieses Konto wurde deaktiviert"},
    "acct.err.deactivated.explanation" =>
      {"You cannot use the account page with a deactivated account.",
       "Mit einem deaktivierten Konto können Sie die Kontoseite nicht nutzen."},
    "acct.err.deactivated.primary" =>
      {"Contact your administrator if you think this is a mistake.",
       "Wenden Sie sich an Ihre Administration, falls Sie das für einen Fehler halten."},
    "acct.err.reauth_failed.title" => {"Sign-in could not be confirmed", "Anmeldung konnte nicht bestätigt werden"},
    "acct.err.reauth_failed.heading" =>
      {"Your sign-in could not be confirmed", "Ihre Anmeldung konnte nicht bestätigt werden"},
    "acct.err.reauth_failed.explanation" =>
      {"Your company sign-in did not ask you to sign in again, so this sign-in cannot be trusted for account changes.",
       "Ihre Firmen-Anmeldung hat Sie nicht erneut zur Anmeldung aufgefordert, deshalb kann dieser Anmeldung für Kontoänderungen nicht vertraut werden."},
    "acct.err.reauth_failed.primary" =>
      {"Open the account page again and enter your password when asked.",
       "Öffnen Sie die Kontoseite erneut und geben Sie Ihr Passwort ein, wenn Sie danach gefragt werden."},
    "acct.err.access_denied.title" => {"Sign-in not completed", "Anmeldung nicht abgeschlossen"},
    "acct.err.access_denied.heading" => {"Sign-in was not completed", "Die Anmeldung wurde nicht abgeschlossen"},
    "acct.err.access_denied.explanation" =>
      {"The sign-in with your company account did not succeed.", "Die Anmeldung mit Ihrem Firmenkonto war nicht erfolgreich."},
    "acct.err.access_denied.primary" =>
      {"Open the account page again to try again.", "Öffnen Sie die Kontoseite erneut, um es noch einmal zu versuchen."},
    "acct.err.server_error.title" => {"Something went wrong", "Etwas ist schiefgelaufen"},
    "acct.err.server_error.heading" => {"Something went wrong", "Etwas ist schiefgelaufen"},
    "acct.err.server_error.explanation" =>
      {"The server ran into an unexpected problem. Nothing was changed.",
       "Auf dem Server ist ein unerwartetes Problem aufgetreten. Es wurde nichts geändert."},
    "acct.err.server_error.primary" =>
      {"Go back to your app and start again.", "Kehren Sie zu Ihrer App zurück und beginnen Sie erneut."}
  }

  # A key without a non-empty text in BOTH languages fails the build.
  for {key, {en, de}} <- @catalog do
    if not (is_binary(en) and String.trim(en) != "" and is_binary(de) and String.trim(de) != "") do
      raise CompileError, description: "Nebu.Web.PageText: key #{inspect(key)} needs a non-empty English and German text"
    end
  end

  @doc """
  A relative time as text in `lang`: `delta_seconds` < 0 is the past ("5 minutes ago" / "vor 5 Minuten"), > 0 the future
  ("in 8 minutes" / "in 8 Minuten"); under one minute "just now" / "gerade eben". Minutes up to 59, then hours up to 23, then
  days; singular and plural from the catalog (`rel.*`).
  """
  @spec relative(integer(), :en | :de) :: String.t()
  def relative(delta_seconds, lang) when is_integer(delta_seconds) and lang in [:en, :de] do
    {direction, seconds} = if delta_seconds < 0, do: {"past", -delta_seconds}, else: {"future", delta_seconds}
    minutes = div(seconds, 60)

    cond do
      minutes == 0 -> fetch!("rel.now", lang)
      minutes < 60 -> relative_unit(direction, "minute", minutes, lang)
      minutes < 1440 -> relative_unit(direction, "hour", div(minutes, 60), lang)
      true -> relative_unit(direction, "day", div(minutes, 1440), lang)
    end
  end

  defp relative_unit(direction, unit, n, lang) do
    form = if n == 1, do: "one", else: "other"
    "rel.#{direction}.#{unit}.#{form}" |> fetch!(lang) |> String.replace("{n}", Integer.to_string(n))
  end

  @doc "Every catalog key."
  @spec keys() :: [String.t()]
  def keys, do: Map.keys(@catalog)

  @doc """
  The text for `key` in `lang` (`:en` | `:de`). An unknown key raises `ArgumentError`: a missing
  key is a programming error that must never render as a blank.
  """
  @spec fetch!(String.t(), :en | :de) :: String.t()
  def fetch!(key, lang) when lang in [:en, :de] do
    case Map.fetch(@catalog, key) do
      {:ok, {en, _de}} when lang == :en -> en
      {:ok, {_en, de}} -> de
      :error -> raise ArgumentError, "Nebu.Web.PageText: missing key #{inspect(key)}"
    end
  end
end
