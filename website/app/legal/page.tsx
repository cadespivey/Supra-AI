import { FeedbackWarning } from "@/components/FeedbackWarning";
import { PageShell } from "@/components/PageShell";

type Item = { title: string; body: string };
type Group = { heading: string; items: Item[] };

const groups: Group[] = [
  {
    heading: "What Supra AI is — and isn't",
    items: [
      {
        title: "A tool, not a lawyer",
        body: "Supra AI is a legal research, writing, and timekeeping assistant. It is software — not a law firm, not an attorney, and not a substitute for one. It is built to complement the skills legal professionals spend years developing, not to replace the judgment those skills produce.",
      },
      {
        title: "Not legal advice",
        body: "Nothing Supra AI produces is legal advice or a professional opinion. Its outputs are research and drafting assistance meant to support a licensed attorney's independent judgment — never to stand in for it.",
      },
      {
        title: "No attorney-client relationship",
        body: "Using Supra AI does not create an attorney-client relationship with Supra AI or any other entity, including model providers or app contributors. The software does not represent any party and does not practice law.",
      },
      {
        title: "Consult an attorney for specific guidance",
        body: "For advice about a specific situation, consult a licensed attorney admitted in your jurisdiction. Only a lawyer who knows the facts of your matter and the law that governs it can advise you on what to do.",
      },
    ],
  },
  {
    heading: "Using it responsibly",
    items: [
      {
        title: "Attorney review required",
        body: "Every output is intended to be reviewed, corrected, and approved by a qualified attorney before it is used, filed, or relied upon. You remain responsible for the accuracy and appropriateness of all work product.",
      },
      {
        title: "Verify every citation and quotation",
        body: "AI-generated citations and quotations can be incomplete, mismatched, or fabricated. Verify every authority, pin cite, and quotation against the original source before relying on it.",
      },
      {
        title: "Jurisdiction and procedural rules",
        body: "Supra AI does not determine the law, court rules, or procedural requirements that apply to your matter. Confirm jurisdiction, current authority, filing deadlines, and local rules independently.",
      },
      {
        title: "Public records are as filed",
        body: "Public-records results — SEC EDGAR filings, CFPB complaints, and NLRB case records — reflect filings and allegations as submitted, not findings or conclusions, and should be confirmed against the official record.",
      },
    ],
  },
  {
    heading: "Terms of use",
    items: [
      {
        title: "Use of Supra AI",
        body: "Supra AI is for use by legal professionals. You are responsible for using it in compliance with applicable law and the rules of professional conduct in your jurisdiction.",
      },
      {
        title: "Local processing; no training on your data",
        body: "Supra AI runs on your device and has no cloud-generation or training backend that receives prompts, documents, or generated work. Local models arrive pre-trained and change when you install a provider version.",
      },
      {
        title: "Software availability and changes",
        body: "We may modify, suspend, or discontinue any part of the software at any time, without notice. We are not obligated to provide updates, support, or backward compatibility.",
      },
      {
        title: "Feedback submissions",
        body: "Feedback you submit through public channels is public. Do not include confidential or privileged information. By submitting feedback, you allow it to be used to improve the software.",
      },
      {
        title: "No warranty",
        body: "The software is provided “as is” and “as available,” without warranties of any kind, express or implied, including merchantability, fitness for a particular purpose, accuracy, and non-infringement, to the fullest extent permitted by law.",
      },
      {
        title: "Limitation of liability",
        body: "To the fullest extent permitted by law, the developers are not liable for any indirect, incidental, or consequential damages, or for any loss arising from use of or reliance on the software or its outputs.",
      },
    ],
  },
];

export default function LegalPage() {
  return (
    <PageShell
      eyebrow="Legal"
      title="Terms & Disclaimer"
      intro="Supra AI is a legal research, writing, and timekeeping assistant. It is not a lawyer, and it is not a substitute for one. These terms are written conservatively for a tool that legal professionals rely on."
    >
      <div className="space-y-16">
        {groups.map((group) => (
          <section key={group.heading}>
            <h2 className="border-b-2 border-supra-gold/60 pb-4 font-caps text-sm uppercase tracking-wide text-supra-gold">
              {group.heading}
            </h2>
            <div className="mt-8 grid gap-x-12 gap-y-8 md:grid-cols-2">
              {group.items.map((item) => (
                <div key={item.title}>
                  <h3 className="text-xl text-supra-white">{item.title}</h3>
                  <p className="measure-wide mt-3 text-base leading-[1.55] text-supra-muted">
                    {item.body}
                  </p>
                </div>
              ))}
            </div>
          </section>
        ))}

        <section className="border-t border-supra-border pt-8">
          <FeedbackWarning />
        </section>
      </div>
    </PageShell>
  );
}
