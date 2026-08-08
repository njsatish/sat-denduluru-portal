const BRAND = process.env.BRAND_NAME || "SAT Denduluru";
const LOGIN_URL =
  process.env.LOGIN_URL ||
  "https://dev-sat.denduluru.com/login.html";
const SITE_URL =
  process.env.SITE_URL ||
  "https://dev-sat.denduluru.com";
const SUPPORT_EMAIL =
  process.env.SUPPORT_EMAIL ||
  "thenuthulapatis@gmail.com";
const SUPPORT_PHONE_DISPLAY =
  process.env.SUPPORT_PHONE_DISPLAY ||
  "804-313-9765";
const SUPPORT_PHONE_E164 =
  process.env.SUPPORT_PHONE_E164 ||
  "+18043139765";

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function replaceAllLiteral(value, token, replacement) {
  return String(value).split(token).join(replacement);
}

const EMAIL_TEMPLATE = "<!doctype html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>Welcome to SAT Denduluru</title>\n</head>\n<body style=\"margin:0;padding:0;background-color:#f3f6fb;font-family:Arial,Helvetica,sans-serif;color:#182033;\">\n  <table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"width:100%;background-color:#f3f6fb;margin:0;padding:0;\">\n    <tr>\n      <td align=\"center\" style=\"padding:28px 12px;\">\n        <table role=\"presentation\" width=\"620\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"width:100%;max-width:620px;background-color:#ffffff;border-radius:18px;overflow:hidden;box-shadow:0 8px 28px rgba(22,34,55,.12);\">\n\n          <!-- Header -->\n          <tr>\n            <td align=\"center\" style=\"background-color:#16233f;padding:34px 26px 28px;\">\n              <div style=\"display:inline-block;background-color:#f5c451;color:#16233f;font-weight:800;font-size:22px;line-height:54px;width:54px;height:54px;border-radius:14px;text-align:center;margin-bottom:14px;\">\n                SAT\n              </div>\n              <div style=\"font-size:28px;line-height:34px;font-weight:800;color:#ffffff;\">\n                Welcome to SAT Denduluru\n              </div>\n              <div style=\"font-size:15px;line-height:23px;color:#cdd7ea;margin-top:8px;\">\n                Your personalized SAT preparation account is ready.\n              </div>\n            </td>\n          </tr>\n\n          <!-- Welcome -->\n          <tr>\n            <td style=\"padding:30px 34px 10px;\">\n              <div style=\"font-size:20px;line-height:28px;font-weight:700;color:#17213a;\">\n                Hello __DISPLAY_NAME__,\n              </div>\n              <div style=\"font-size:15px;line-height:24px;color:#566075;margin-top:10px;\">\n                Your student account has been created for <strong>SAT Denduluru</strong>.\n                Use the temporary credentials below to sign in for the first time.\n                You will be asked to create your own password after signing in.\n              </div>\n            </td>\n          </tr>\n\n          <!-- Credentials -->\n          <tr>\n            <td style=\"padding:18px 34px;\">\n              <table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"width:100%;background-color:#fff8e5;border:1px solid #f2d67d;border-radius:14px;\">\n                <tr>\n                  <td style=\"padding:22px 24px;\">\n                    <div style=\"font-size:13px;line-height:18px;font-weight:800;letter-spacing:.7px;color:#8b6a13;text-transform:uppercase;\">\n                      Your login credentials\n                    </div>\n\n                    <div style=\"margin-top:16px;font-size:14px;line-height:22px;color:#5d6470;\">\n                      Username\n                    </div>\n                    <div style=\"font-size:19px;line-height:26px;font-weight:800;color:#17213a;\">\n                      __USERNAME_PARAMETER__\n                    </div>\n\n                    <div style=\"margin-top:14px;font-size:14px;line-height:22px;color:#5d6470;\">\n                      Temporary password\n                    </div>\n                    <div style=\"font-size:19px;line-height:26px;font-weight:800;color:#b24b30;word-break:break-all;\">\n                      __CODE_PARAMETER__\n                    </div>\n                  </td>\n                </tr>\n              </table>\n            </td>\n          </tr>\n\n          <!-- Login CTA -->\n          <tr>\n            <td align=\"center\" style=\"padding:8px 34px 28px;\">\n              <table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\">\n                <tr>\n                  <td align=\"center\" bgcolor=\"#2b6de8\" style=\"border-radius:10px;\">\n                    <a href=\"__LOGIN_URL__\"\n                       style=\"display:inline-block;padding:14px 28px;font-size:16px;line-height:20px;font-weight:800;color:#ffffff;text-decoration:none;border-radius:10px;\">\n                      Sign in to SAT Denduluru\n                    </a>\n                  </td>\n                </tr>\n              </table>\n              <div style=\"font-size:12px;line-height:19px;color:#8b93a3;margin-top:12px;\">\n                If the button does not open, use:<br>\n                <a href=\"__LOGIN_URL__\" style=\"color:#2b6de8;text-decoration:none;\">\n                  __LOGIN_URL__\n                </a>\n              </div>\n            </td>\n          </tr>\n\n          <!-- What you get -->\n          <tr>\n            <td style=\"padding:0 34px 24px;\">\n              <div style=\"font-size:18px;line-height:26px;font-weight:800;color:#17213a;margin-bottom:13px;\">\n                What you can practice\n              </div>\n\n              <table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\">\n                <tr>\n                  <td valign=\"top\" width=\"50%\" style=\"padding:0 6px 12px 0;\">\n                    <div style=\"background-color:#edf4ff;border:1px solid #cfe0ff;border-radius:12px;padding:16px;\">\n                      <div style=\"font-size:16px;font-weight:800;color:#2456aa;\">\u2797 SAT Math</div>\n                      <div style=\"font-size:13px;line-height:20px;color:#5d6677;margin-top:6px;\">\n                        600 practice questions with progress tracking, review, and correction practice.\n                      </div>\n                    </div>\n                  </td>\n                  <td valign=\"top\" width=\"50%\" style=\"padding:0 0 12px 6px;\">\n                    <div style=\"background-color:#f0fbf6;border:1px solid #cceedd;border-radius:12px;padding:16px;\">\n                      <div style=\"font-size:16px;font-weight:800;color:#1e7c52;\">\ud83d\udcda SAT English</div>\n                      <div style=\"font-size:13px;line-height:20px;color:#5d6677;margin-top:6px;\">\n                        375 vocabulary words, flashcards, spelling, quizzes, and progress tracking.\n                      </div>\n                    </div>\n                  </td>\n                </tr>\n                <tr>\n                  <td colspan=\"2\" style=\"padding-top:0;\">\n                    <div style=\"background-color:#fff2f7;border:1px solid #f4cfdd;border-radius:12px;padding:16px;\">\n                      <div style=\"font-size:16px;font-weight:800;color:#a63f68;\">\u270d\ufe0f Reading &amp; Writing</div>\n                      <div style=\"font-size:13px;line-height:20px;color:#5d6677;margin-top:6px;\">\n                        SAT-style Reading &amp; Writing practice to build accuracy, vocabulary, and test confidence.\n                      </div>\n                    </div>\n                  </td>\n                </tr>\n              </table>\n            </td>\n          </tr>\n\n          <!-- First login note -->\n          <tr>\n            <td style=\"padding:0 34px 28px;\">\n              <table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"width:100%;background-color:#f8f9fc;border-left:4px solid #6b7ca8;border-radius:8px;\">\n                <tr>\n                  <td style=\"padding:15px 17px;font-size:13px;line-height:21px;color:#596273;\">\n                    <strong style=\"color:#27334d;\">First-time login:</strong>\n                    Enter the username and temporary password above. For security, you will then be asked to choose a new password.\n                  </td>\n                </tr>\n              </table>\n            </td>\n          </tr>\n\n          <!-- Help -->\n          <tr>\n            <td style=\"padding:24px 34px;background-color:#17213a;\">\n              <div style=\"font-size:16px;line-height:22px;font-weight:800;color:#ffffff;\">\n                Need help?\n              </div>\n              <div style=\"font-size:13px;line-height:22px;color:#cbd4e6;margin-top:8px;\">\n                Email:\n                <a href=\"mailto:__SUPPORT_EMAIL__\" style=\"color:#f5c451;text-decoration:none;\">\n                  __SUPPORT_EMAIL__\n                </a>\n                <br>\n                Text:\n                <a href=\"sms:__SUPPORT_PHONE_E164__\" style=\"color:#f5c451;text-decoration:none;\">\n                  __SUPPORT_PHONE_DISPLAY__\n                </a>\n              </div>\n\n              <div style=\"font-size:12px;line-height:20px;color:#93a0ba;margin-top:18px;padding-top:16px;border-top:1px solid #33415e;\">\n                SAT Denduluru \u00b7\n                <a href=\"__SITE_URL__\" style=\"color:#b9c8e8;text-decoration:none;\">\n                  sat.denduluru.com\n                </a>\n                <br>\n                This is an automated account invitation. Please do not reply directly to this message.\n              </div>\n            </td>\n          </tr>\n\n        </table>\n\n        <div style=\"max-width:620px;margin:14px auto 0;font-size:11px;line-height:17px;color:#8b93a3;text-align:center;\">\n          This message was sent because an SAT Denduluru student account was created using this email address.\n        </div>\n      </td>\n    </tr>\n  </table>\n</body>\n</html>\n";

function buildAdminCreateUserEmail(event) {
  const usernameParameter =
    event?.request?.usernameParameter || "{username}";
  const codeParameter =
    event?.request?.codeParameter || "{####}";

  const displayName =
    String(
      event?.request?.userAttributes?.name ||
      event?.userName ||
      "Student"
    ).trim() || "Student";

  let html = EMAIL_TEMPLATE;

  const replacements = {
    "__DISPLAY_NAME__": escapeHtml(displayName),
    "__USERNAME_PARAMETER__": usernameParameter,
    "__CODE_PARAMETER__": codeParameter,
    "__LOGIN_URL__": escapeHtml(LOGIN_URL),
    "__SITE_URL__": escapeHtml(SITE_URL),
    "__SUPPORT_EMAIL__": escapeHtml(SUPPORT_EMAIL),
    "__SUPPORT_PHONE_DISPLAY__":
      escapeHtml(SUPPORT_PHONE_DISPLAY),
    "__SUPPORT_PHONE_E164__":
      escapeHtml(SUPPORT_PHONE_E164)
  };

  for (const [token, replacement] of
    Object.entries(replacements)) {
    html =
      replaceAllLiteral(
        html,
        token,
        replacement
      );
  }

  return html;
}

export async function handler(event) {
  if (
    event?.triggerSource ===
    "CustomMessage_AdminCreateUser"
  ) {
    event.response ||= {};
    event.response.emailSubject =
      `Welcome to ${BRAND} – Your Student Account`;
    event.response.emailMessage =
      buildAdminCreateUserEmail(event);
  }

  return event;
}
