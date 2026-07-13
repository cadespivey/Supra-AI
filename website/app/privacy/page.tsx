import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  {
    title: "We don't see or control your data",
    body: "There is no Supra AI account, server, or cloud backend that receives your work. Your matter documents, prompts, embeddings, chats, and generated work product are created and stored on your Mac. We have no way to read, collect, or control any of it.",
  },
  {
    title: "Everything runs on your device",
    body: "Generation, document extraction and indexing, embeddings, semantic search, drafting, and timekeeping run locally on your machine. The app does not send matter content to Supra AI or to a cloud-generation service.",
  },
  {
    title: "Your work is not sent for model training",
    body: "Supra AI has no account or cloud-generation backend that receives prompts, documents, or generated work. Local models arrive pre-trained; model downloads request provider artifacts without attaching matter content.",
  },
  {
    title: "Research requests you run",
    body: "Legal-research and public-records searches send the query fields required by the named provider: CourtListener, official statutes and regulations sources, SEC EDGAR, the CFPB complaint database, or the NLRB. Application tests require these request builders to omit matter documents, prompts, and generated work.",
  },
  {
    title: "Searches you can see and adjust",
    body: "Research searches are sent as ordinary query terms — the words and connectors that make up the search — which you can review and adjust before and after you run them. You choose which connectors to enable; several need no key at all, and any API keys you add are stored in the macOS Keychain and sent only to the provider they belong to.",
  },
  {
    title: "Software downloads and updates",
    body: "Model setup requests revision-bound metadata and model artifacts from named Hugging Face origins. When enabled, Sparkle checks the signed Supra AI update feed and may fetch its signed update. These clients do not attach matter content or legal-data credentials.",
  },
  {
    title: "No application telemetry",
    body: "The application contains no analytics or telemetry client and sends no prompt, document, legal query, or usage event to Supra AI.",
  },
  {
    title: "This website",
    body: "This site is static, hosted on GitHub Pages. It sets no cookies and runs no analytics or tracking. As host, GitHub may log ordinary technical request data such as IP addresses to operate the service.",
  },
];

export default function PrivacyPage() {
  return (
    <PageShell
      eyebrow="Privacy"
      title="Privacy Policy"
      intro="The short version: we do not operate a cloud backend that receives your work. Processing is local, with named research and software-delivery requests described below."
    >
      <div className="mb-12 border-l-2 border-supra-gold/60 pl-5">
        <p className="font-caps text-xs uppercase text-supra-gold">
          In one sentence
        </p>
        <p className="measure-wide mt-2 text-lg leading-[1.5] text-supra-white">
          Matter processing and generation run on your device. Named legal-data
          providers receive the searches you run; model and update providers receive
          software metadata requests, without matter documents or generated work.
        </p>
      </div>

      <div className="grid gap-x-12 gap-y-8 md:grid-cols-2">
        {sections.map((section) => (
          <section
            key={section.title}
            className="border-t border-supra-border pt-5"
          >
            <h2 className="text-xl text-supra-white">{section.title}</h2>
            <p className="measure-wide mt-3 text-base leading-[1.55] text-supra-muted">
              {section.body}
            </p>
          </section>
        ))}
        <section className="pt-2 md:col-span-2">
          <FeedbackWarning />
        </section>
      </div>
    </PageShell>
  );
}
