import { DraftNotice } from "@/components/DraftNotice";
import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  {
    title: "Website data",
    body: "This website is a static site hosted on GitHub Pages. It sets no cookies and runs no analytics or tracking scripts. GitHub, as host, may automatically log standard technical request data such as IP addresses and user-agent strings to operate and protect the service.",
  },
  {
    title: "Download data",
    body: "When you download the app from GitHub Releases, GitHub may record aggregate download counts and standard server logs. We do not add separate download trackers or marketing pixels.",
  },
  {
    title: "Local app data",
    body: "The Supra AI app is designed to run locally. Your matter documents, prompts, embeddings, and generated work product are processed on your Mac and are not sent to us. We operate no server that receives your matter content.",
  },
  {
    title: "CourtListener research",
    body: "When you enable CourtListener research, the app sends your search queries to the CourtListener API to retrieve authority. This is the opt-in network feature for legal research. Review CourtListener's own terms and privacy policy for how they handle requests.",
  },
  {
    title: "Model downloads and updates",
    body: "On first launch the app downloads local model weights, and it may check GitHub for new releases so it can tell you when an update is available. These send only the information needed to fetch software and check versions — not your matter content.",
  },
  {
    title: "Cookies and analytics",
    body: "Neither the website nor the app uses advertising cookies or third-party analytics by default. If this changes before launch, this policy will be updated to describe what is collected and why.",
  },
  {
    title: "Data you should not submit",
    body: "Do not place privileged, confidential, or client-identifying information into any public channel such as GitHub Issues. See the public-feedback warning below.",
  },
  {
    title: "Changes to this policy",
    body: "This policy is a pre-launch draft and may change as the product matures. Material changes will be reflected here, and the version published at launch will govern.",
  },
  {
    title: "Contact",
    body: "For privacy questions during the beta, open a non-sensitive issue on GitHub. A dedicated contact address will be published before general release.",
  },
];

export default function PrivacyPage() {
  return (
    <PageShell
      eyebrow="Privacy"
      title="Privacy Policy"
      intro="Supra AI is built around local processing. This policy explains the limited data the website and app touch."
    >
      <DraftNotice />
      <div className="mb-6 rounded-2xl border border-supra-gold/35 bg-supra-navyPanel p-6">
        <h2 className="text-2xl text-supra-white">The short version</h2>
        <p className="mt-4 text-base leading-7 text-supra-muted">
          The app processes your matter documents and generated work locally on
          your Mac and does not send them to us. Aside from fetching the app and
          its models and checking for updates, optional CourtListener research is
          the only feature that uses the network. This website is static, with no
          cookies or analytics; its host may log ordinary request data.
        </p>
      </div>

      <div className="grid gap-5 md:grid-cols-2">
        {sections.map((section) => (
          <section
            key={section.title}
            className="rounded-2xl border border-supra-border bg-supra-navyPanel p-6"
          >
            <h2 className="text-2xl text-supra-white">{section.title}</h2>
            <p className="mt-4 text-base leading-7 text-supra-muted">
              {section.body}
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
