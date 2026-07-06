import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

const sections = [
  {
    title: "We don't see or control your data",
    body: "There is no Supra AI account, server, or cloud backend that receives your work. Your matter documents, prompts, embeddings, chats, and generated work product are created and stored on your Mac. We have no way to read, collect, or control any of it.",
  },
  {
    title: "Everything runs on your device",
    body: "Generation, document extraction and indexing, embeddings, semantic search, drafting, and timekeeping all run locally on your machine. Nothing about your matters leaves your Mac for us or for a cloud model.",
  },
  {
    title: "Your work never trains a model",
    body: "Because nothing you do leaves your Mac, your prompts, documents, and generated work are never used to train, fine-tune, or improve any model. The local models come already trained; new versions arrive only if and when you choose to download a provider update. Your inputs and outputs are never harvested as training data — by us or by anyone.",
  },
  {
    title: "The one exception: research you run",
    body: "The only time information leaves your Mac is when you run a legal-research or public-records search — case law and dockets through CourtListener, statutes and regulations through official government sources, and public records through SEC EDGAR, the CFPB complaint database, and the NLRB. Those requests carry your search terms, never your documents or work product, and they go directly to the source you queried.",
  },
  {
    title: "Searches you can see and adjust",
    body: "Research searches are sent as ordinary query terms — the words and connectors that make up the search — which you can review and adjust before and after you run them. You choose which connectors to enable; several need no key at all, and any API keys you add are stored in the macOS Keychain and sent only to the provider they belong to.",
  },
  {
    title: "Software downloads and updates",
    body: "To run, the app downloads its local model weights the first time you use them and can check for new versions so it can tell you when an update is available. These requests fetch software and check versions only — they never include your matter content.",
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
      intro="The short version: we don't see or control your data. Almost everything you do in Supra AI happens on your own Mac."
    >
      <div className="mb-12 border-l-2 border-supra-gold/60 pl-5">
        <p className="font-caps text-xs uppercase text-supra-gold">
          In one sentence
        </p>
        <p className="measure-wide mt-2 text-lg leading-[1.5] text-supra-white">
          Everything you do runs on your device, except the legal-research and
          public-records searches you choose to run — and those send only the
          query terms you can see and adjust, never your documents.
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
