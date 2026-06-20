import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  "Website data",
  "Download and analytics data",
  "Local app data",
  "CourtListener research",
  "Cookies and analytics",
  "Data you should not submit",
  "Changes to this policy",
  "Contact",
];

export default function PrivacyPage() {
  return (
    <PageShell
      eyebrow="Privacy"
      title="Privacy Policy"
      intro="This privacy policy is a conservative draft for review before public launch."
    >
      <div className="mb-6 rounded-2xl border border-supra-gold/35 bg-supra-navyPanel p-6">
        <h2 className="text-2xl text-supra-white">Important distinction</h2>
        <p className="mt-4 text-base leading-7 text-supra-muted">
          The website may collect ordinary web or download-related data
          depending on hosting and analytics configuration. The Supra AI app is
          designed for local processing, with CourtListener research as the
          limited network exception when enabled.
        </p>
      </div>

      <div className="grid gap-5 md:grid-cols-2">
        {sections.map((section) => (
          <section
            key={section}
            className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6"
          >
            <h2 className="text-2xl text-supra-white">{section}</h2>
            <p className="mt-4 text-base leading-7 text-supra-muted">
              This policy section is structured for review before public launch.
            </p>
          </section>
        ))}
        <section className="md:col-span-2">
          <FeedbackWarning />
        </section>
      </div>
    </PageShell>
  );
}
