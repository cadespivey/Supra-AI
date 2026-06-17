# Milestone 3 — Document Intelligence Validation Plan

Seeded test corpus + answer keys for putting the app through its paces. Three matters live under `TestData/<matter>/`. Each matter folder is import-ready: drag it (or its subfolders) into the matter's **Documents** tab.

## Prerequisites
1. **Settings → Document Intelligence**: chat model loaded (Models tab), an embedding model downloaded + test-loaded, storage initialized → *Setup complete*.
2. Create a matter per section below and import the corresponding `TestData/<matter>/` folder. Wait for the processing queue to finish (all docs **Ready**).
3. CourtListener: add your API token in **Settings → CourtListener** to run the research scenarios.

## Automated pre-check (no chat model needed)
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path Packages/SupraTestKit` regenerates each matter, imports with **real OCR**, indexes, and asserts every planted fact is extractable (incl. OCR-only docs) and that `.msg` is reported unsupported.

## Format / OCR coverage

| Matter | pdf | scanned_pdf | image_png | docx | xlsx | eml | msg |
|---|---|---|---|---|---|---|---|
| Bayfront Steel & Supply, LLC v. Coas… | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Calloway v. Heron Bay Holdings, LLC … | ✓ | ✓ | — | ✓ | ✓ | ✓ | ✓ |
| Calloway v. Lee County & Tidewater M… | ✓ | ✓ | — | ✓ | ✓ | ✓ | ✓ |

---

## Bayfront Steel & Supply, LLC v. Coastal Marine Constructors, Inc. (Port Verano Berth 7 Reconstruction)
*Construction Litigation — Construction Lien & Collection (Public Project / Payment Bond) — Florida — 13th Judicial Circuit, Hillsborough County — perspective: plaintiff*

Subcontractor/supplier Bayfront Steel & Supply, LLC seeks unpaid amounts for structural steel and rebar furnished to general contractor Coastal Marine Constructors, Inc. on the Port Verano Authority's Berth 7 reconstruction. Because the project sits on land owned by a public port authority, the claim implicates whether a Chapter 713 construction lien can attach and whether recovery must instead proceed against the Section 255.05 public payment bond.

**Documents:**
- `Contracts/subcontract-agreement.pdf` — Born-digital PDF establishing parties, scope, contract sum, the buried pay-when-paid/cure clause, and the public-owner fact that drives the lien-vs-bond analysis.
- `Financials/payment-draw-ledger.xlsx` — Spreadsheet whose computed unpaid balance ($163,815.00) deliberately contradicts the $182,340.00 figure in the demand letter; contains ledger-only computation facts (the freight true-up and the net-balance derivation).
- `Correspondence/demand-letter.docx` — Word demand letter that overstates the amount due relative to the ledger, creating the deliberate cross-document contradiction; also tests born-digital text extraction.
- `Pleadings/claim-of-lien-recorded.pdf` — OCR-only scanned image of the recorded Claim of Lien; carries the official recording date, O.R. book/page, and lien amount that match the ledger (not the demand letter). Tests OCR extraction. *(OCR-only)*
- `Evidence/delivery-receipt-lot4.png` — OCR-only photograph of a signed delivery ticket proving the disputed Lot 4 materials were delivered and signed for; the only place the signed delivery ticket number and receiver name appear. Tests OCR. *(OCR-only)*
- `Correspondence/payment-dispute-thread.eml` — Email thread documenting the payment dispute and the pay-when-paid defense raised by the GC, with the lien-notice document attached. Tests eml parsing plus attachment extraction.
- `Correspondence/pm-status-update.msg` — Outlook .msg from the project manager; the app reports this format as UNSUPPORTED. Used to exercise the unsupported-import-report path. No required Q&A answer depends on it. *(unsupported — import report should flag it)*
- `Pleadings/lien-vs-bond-research-memo.pdf` — Born-digital internal research memo framing the public-property lien-vs-bond question and the strict-compliance issue; supports the cross-document synthesis question and the CourtListener legal issue.
- Plus real Florida authorities/procedure in `Caselaw & Procedure/`.

### Q&A scenarios (Documents → Ask)
| # | Question | Expected answer | Source | Flags |
|---|---|---|---|---|
| 1 | What is the total Contract Sum under the steel and rebar subcontract, and what is the subcontract number? | $487,500.00 under Subcontract No. CMC-BSS-2025-0047. | `subcontract-agreement.pdf` Section 3 (Contract Sum); header subcontract number |  |
| 2 | What does Section 14.3 of the subcontract require before a party may file suit, and what type of payment provision does it contain? | It contains a pay-when-paid conditional-payment provision (the contractor's receipt of payment from the Owner is a condition precedent) and requires written notice of default with a 45-day opportunity to cure before any action is commenced. | `subcontract-agreement.pdf` Section 14.3 (Conditional Payment; Cure) |  |
| 3 | What net unpaid balance does Bayfront's draw ledger actually compute to? | $163,815.00 (NET UNPAID BALANCE line). | `payment-draw-ledger.xlsx` Draw Ledger sheet, final 'NET UNPAID BALANCE' row |  |
| 4 | What dollar amount does the demand letter state is owed, and how does it conflict with the draw ledger? | The demand letter demands $182,340.00, but the draw ledger nets to $163,815.00 — an $18,525.00 overstatement that appears to double-count the disputed Lot 4 rebar back-charge. This is the deliberate cross-document contradiction. | `demand-letter.docx` Demand paragraph ('$182,340.00') vs. ledger NET UNPAID BALANCE | cross-doc |
| 5 | On what date was the Claim of Lien recorded, and in what Official Records book and page? | Recorded March 11, 2026, in Official Records Book 28714, Page 1902, Hillsborough County (Instrument No. 2026000091847). | `claim-of-lien-recorded.pdf` Recording stamp at top of scanned instrument | OCR |
| 6 | What lien amount is stated on the recorded Claim of Lien, and does it match the ledger or the demand letter? | $163,815.00, which matches the draw ledger's net unpaid balance, not the demand letter's $182,340.00. | `claim-of-lien-recorded.pdf` Paragraph 4 of the Claim of Lien ('$163,815.00') | OCR, cross-doc |
| 7 | Who signed for the Lot 4 delivery, on what date, and under what delivery ticket number? | Curtis Mealy, site superintendent for Coastal Marine Constructors, signed for it on January 19, 2026 under Delivery Ticket No. DT-Lot4-0119. | `delivery-receipt-lot4.png` Receiving block and ticket number on the photographed ticket | OCR |
| 8 | What two defenses to payment does Coastal Marine's controller raise in the email thread, and what is the payment bond identified in the attachment? | He raises (1) pay-when-paid under Section 14.3 (the Authority has not released the Lot 4 pay application) and (2) an $18,525.00 back-charge for the QC-flagged Lot 4 rebar coils. The attached Notice to Owner identifies Bond No. SUR-7741-FL from Gulfstream Surety Company. | `payment-dispute-thread.eml` Body items 1 and 2; attachment 'notice-to-owner.pdf' bond reference |  |
| 9 | Given that the Berth 7 parcel is owned by the Port Verano Authority, what is the firm's recommended primary remedy and why? | Pursue the Section 255.05 payment bond (Bond No. SUR-7741-FL, Gulfstream Surety) as the primary remedy, because a Chapter 713 construction lien cannot attach to public/sovereign property; the recorded lien is preserved only as a precaution. This synthesizes the subcontract's public-owner fact, the bond identified in the NTO attachment, and the research memo's conclusion. | `lien-vs-bond-research-memo.pdf` SHORT ANSWER and RECOMMENDATION sections | cross-doc |
| 10 | By when must any action to enforce the recorded lien be commenced, per the research memo? | Within one year of the March 11, 2026 recording date. | `lien-vs-bond-research-memo.pdf` DISCUSSION point (3) referencing the one-year deadline from recording |  |
| 11 | What is the penal sum (maximum coverage) of the Section 255.05 payment bond? | NOT SUPPORTED — the documents do not answer this. The bond number and surety are identified, but no penal sum / bond amount appears anywhere in the corpus. | `lien-vs-bond-research-memo.pdf` Bond is named (SUR-7741-FL) but no dollar penal sum is stated in any document | **must refuse** |

### Chronology (Documents → Chronology)
| Date | Event | Source |
|---|---|---|
| 2025-08-04 | Bayfront and Coastal Marine execute Subcontract No. CMC-BSS-2025-0047 for Berth 7 steel/rebar ($487,500.00). | `subcontract-agreement.pdf` |
| 2025-09-12 | Bayfront first furnishes materials to the Berth 7 project (per recorded Claim of Lien). | `claim-of-lien-recorded.pdf` |
| 2025-12-30 | Bayfront serves its Notice to Owner on the Port Verano Authority, identifying Bond No. SUR-7741-FL. | `payment-dispute-thread.eml` |
| 2026-01-19 | Lot 4 structural steel and rebar delivered and signed for by superintendent Curtis Mealy (Ticket DT-Lot4-0119). | `delivery-receipt-lot4.png` |
| 2026-02-26 | Bayfront last furnishes materials (final delivery + freight, INV-2026-0228). | `claim-of-lien-recorded.pdf` |
| 2026-03-05 | Coastal Marine's controller asserts pay-when-paid and an $18,525.00 Lot 4 back-charge in the email dispute thread. | `payment-dispute-thread.eml` |
| 2026-03-11 | Claim of Lien recorded in O.R. Book 28714, Page 1902, Hillsborough County (lien amount $163,815.00). | `claim-of-lien-recorded.pdf` |
| 2026-03-24 | Demand letter sent demanding $182,340.00 (overstated vs. ledger). | `demand-letter.docx` |

### CourtListener research
- **Issue:** Whether a subcontractor/supplier's Chapter 713 construction lien can attach to land owned by a public port authority, or whether its exclusive remedy for unpaid materials on a public project is a claim against the Section 255.05, Florida Statutes payment bond; and the strict-compliance requirements (Notice to Owner) governing such claims.
- **Jurisdiction filter:** Florida (Supreme Court of Florida and District Courts of Appeal)
- **Expected authorities:** Deen v. Tampa Port Authority, 207 So. 2d 688 (Fla. 1967), City of Gainesville v. Republic Investors Corp., Fla. Stat. § 255.05 (public-project payment bond), Fla. Stat. ch. 713 (Construction Lien Law); § 713.08 (Claim of Lien)

---

## Calloway v. Heron Bay Holdings, LLC — Purchase & Sale of 4412 Bayshore Blvd
*Real Estate Litigation — Residential/Commercial Purchase & Sale; Specific Performance — Florida — 13th Judicial Circuit, Hillsborough County (Tampa) — perspective: plaintiff*

Buyer Marcus Calloway seeks specific performance of a $1,275,000 purchase and sale agreement for a mixed-use property at 4412 Bayshore Blvd, Tampa, after seller Heron Bay Holdings, LLC refused to close, claiming the financing/inspection contingency lapsed. The matter turns on conflicting closing-date representations and an inspection defect surfaced only by OCR.

**Documents:**
- `Contracts/psa-4412-bayshore-executed.pdf` — Born-digital primary contract; tests extraction of purchase price, earnest money, contingency deadline, closing date, parties, and a buried clause. Anchor for the closing-date contradiction.
- `Financials/closing-statement-settlement-sheet.xlsx` — Settlement/closing figures; tests numeric extraction from spreadsheet cells, including a spreadsheet-only hidden fact (undisclosed lien payoff line) and reconciliation against the PSA price and earnest money.
- `Evidence/inspection-report-scanned.pdf` — OCR-only scanned home/commercial inspection. Tests OCR extraction of a material defect that appears nowhere else and is not disclosed in correspondence. Any Q&A relying on the roof-leak defect MUST set requiresOCR:true. *(OCR-only)*
- `Contracts/addendum-no-1-financing-extension.docx` — Editable addendum; tests docx extraction and whether the app links an amendment back to the base PSA. Reinforces the April 10 closing date and adds an addendum-specific identifier.
- `Correspondence/financing-contingency-status.eml` — Email with attachment; tests eml parsing AND attachment extraction. Plants the deliberate closing-date CONTRADICTION (states closing as March 31, 2026) against the PSA/Addendum (April 10, 2026). Attachment is the lender loan commitment.
- `Contracts/title-commitment-gulfstream.pdf` — Born-digital title commitment; tests extraction of legal description, exceptions, and cross-reference of the Schedule B-II code-enforcement lien to the spreadsheet's undisclosed lien payoff line (cross-document synthesis).
- `Correspondence/realtor-message-from-coastline.msg` — Unsupported format; exercises the unsupported-import / parse-failure reporting path. NO required Q&A answer is placed behind this file. Mirrors (but is not the source of record for) the closing-date contradiction. *(unsupported — import report should flag it)*
- Plus real Florida authorities/procedure in `Caselaw & Procedure/`.

### Q&A scenarios (Documents → Ask)
| # | Question | Expected answer | Source | Flags |
|---|---|---|---|---|
| 1 | What is the total purchase price for 4412 Bayshore Blvd? | $1,275,000.00 | `psa-4412-bayshore-executed.pdf` Section 2 (Purchase Price) |  |
| 2 | How much earnest money was deposited and who holds it? | $63,750.00, held by Gulfstream Title & Escrow, LLC under escrow file GT-58821. | `psa-4412-bayshore-executed.pdf` Section 3 (Earnest Money) |  |
| 3 | What is the financing/inspection contingency deadline? | March 14, 2026. | `psa-4412-bayshore-executed.pdf` Section 7.2 (Contingencies) |  |
| 4 | Is there a contradiction in the documents about the closing date, and what is it? | Yes. The executed PSA (§9.1) and Addendum No. 1 set the closing date as April 10, 2026, but the loan officer's financing email (and the realtor .msg) state the closing date as March 31, 2026. The PSA/Addendum is the controlling written agreement; the emails are inconsistent. | `financing-contingency-status.eml` Compare email subject/body (March 31, 2026) against PSA §9.1 and Addendum No. 1 (April 10, 2026) | cross-doc |
| 5 | Was the buyer's written loan commitment issued before the contingency deadline? | Yes. Commitment TBFCU-LC-99214 for $956,250.00 was issued March 11, 2026, which is before the March 14, 2026 contingency deadline. | `financing-contingency-status.eml` Email body and attached loan-commitment-TBFCU-LC-99214.pdf, compared to PSA §7.2 | cross-doc |
| 6 | What material roof defect did the inspection identify, and what is the estimated repair cost? | An active roof leak above second-floor commercial Unit 2C, with water staining and soft decking, estimated to cost $18,500 to repair. | `inspection-report-scanned.pdf` Section 2 (Roofing) — only recoverable via OCR of the scanned report | OCR |
| 7 | Who performed the inspection and under what license number? | Raymond Ostrander of Bayfront Property Inspections, Florida inspector license No. HI-7741. | `inspection-report-scanned.pdf` Report header — requires OCR | OCR |
| 8 | What undisclosed lien appears on the closing statement, and does it match a title exception? | The closing statement shows a $4,800.00 'Undisclosed Lien Payoff — Sunstate Code Enforcement' debited to Seller. This matches Schedule B-II, Exception 7 of the title commitment: a City of Tampa / Sunstate Code Enforcement lien recorded at O.R. Book 28114, Page 0042, for $4,800.00. | `closing-statement-settlement-sheet.xlsx` Settlement sheet 'Undisclosed Lien Payoff' line; cross-reference title-commitment Schedule B-II Exception 7 | cross-doc |
| 9 | What is the estimated cash to close from the buyer? | $262,750.00. | `closing-statement-settlement-sheet.xlsx` Settlement sheet 'ESTIMATED CASH TO CLOSE FROM BUYER' line |  |
| 10 | What closing-cost credit did the seller agree to in Addendum No. 1? | A $7,500.00 credit toward the buyer's closing costs (Addendum Control No. ADD-4412-001, dated March 4, 2026). | `addendum-no-1-financing-extension.docx` Addendum Section 2 (Seller Closing-Cost Credit) |  |
| 11 | What is the recorded legal description of the property? | Lot 12, Block 4, Bayshore Gardens Unit Two, per Plat Book 41, Page 18, Public Records of Hillsborough County, Florida. | `title-commitment-gulfstream.pdf` Schedule A, item 5 (Legal Description) |  |
| 12 | What is the buyer's homeowners' association membership or HOA monthly fee for the property? | NOT SUPPORTED — the documents do not answer this. | `psa-4412-bayshore-executed.pdf` No HOA membership or fee is stated in any document; refusal expected. | **must refuse** |

### Chronology (Documents → Chronology)
| Date | Event | Source |
|---|---|---|
| 2026-02-27 | Purchase and Sale Agreement effective; price $1,275,000, closing set for April 10, 2026. | `psa-4412-bayshore-executed.pdf` |
| 2026-03-04 | Addendum No. 1 (ADD-4412-001) executed; confirms April 10, 2026 closing and adds $7,500 seller credit. | `addendum-no-1-financing-extension.docx` |
| 2026-03-05 | Title commitment GT-TC-58821-A effective; discloses $4,800 code-enforcement lien (Schedule B-II Exception 7). | `title-commitment-gulfstream.pdf` |
| 2026-03-06 | Property inspection performed; active roof leak above Unit 2C documented (OCR-only). | `inspection-report-scanned.pdf` |
| 2026-03-09 | Realtor Tessa Lindqvist emails buyer referencing an (incorrect) March 31 closing and seller 'cold feet'. | `realtor-message-from-coastline.msg` |
| 2026-03-11 | Lender issues written loan commitment TBFCU-LC-99214 ($956,250); email also asserts March 31, 2026 closing (contradicts PSA). | `financing-contingency-status.eml` |
| 2026-03-14 | Financing/inspection contingency deadline under PSA §7.2. | `psa-4412-bayshore-executed.pdf` |
| 2026-04-10 | Contractual closing date under PSA §9.1 and Addendum No. 1. | `psa-4412-bayshore-executed.pdf` |

### CourtListener research
- **Issue:** Whether a buyer may obtain specific performance of a definite, signed Florida real-estate purchase and sale agreement where financing and inspection contingencies were timely satisfied and the seller repudiated, and the related question of whether recorded contract/property records implicate public-records access rather than copyright restriction.
- **Jurisdiction filter:** Florida (Supreme Court of Florida and District Courts of Appeal); 13th Judicial Circuit, Hillsborough County trial venue
- **Expected authorities:** DK Arena, Inc. v. EB Acquisitions I, LLC, 112 So. 3d 85 (Fla. 2013), Microdecisions, Inc. v. Skinner, 889 So. 2d 871 (Fla. 2d DCA 2004)

---

## Calloway v. Lee County & Tidewater Mutual Insurance Co. (Hurricane Wind/Flood Property Claim)
*First-Party Property Insurance / Florida Sovereign Immunity (Tort Claim Against County) — Florida — 20th Judicial Circuit, Lee County — perspective: plaintiff*

First-party homeowners property claim for storm damage to a Cape Coral residence that Tidewater Mutual denied under a flood exclusion, paired with a related tort claim against Lee County for negligent operation of a stormwater pump station alleged to have worsened the flooding. The matter tests coverage interpretation, an OCR-only claim form, a spreadsheet-buried loss figure, a date-of-loss contradiction, and Florida sovereign-immunity pre-suit notice under Fla. Stat. § 768.28.

**Documents:**
- `Policy/tidewater-policy-declarations.pdf` — Born-digital PDF that should be fully text-extractable. Tests retrieval of policy number, limits, deductible, the separate hurricane deductible, and a buried coverage EXCLUSION clause that the denial relies on.
- `Claim File/claim-form-acord-scanned.pdf` — Image-only scanned ACORD-style first notice of loss with NO text layer. Tests OCR extraction of the claim number and the (contradicted) date of loss. Any answer-key question depending on this must set requiresOCR:true. *(OCR-only)*
- `Claim File/adjuster-damages-worksheet.xlsx` — Adjuster's damages worksheet. The total estimated dwelling loss figure appears ONLY in a spreadsheet cell (not in any prose document). Tests spreadsheet cell extraction and computed/located totals.
- `Claim File/calloway-recorded-statement-transcript.docx` — Recorded statement transcript whose stated date of loss CONTRADICTS the claim form. Tests cross-document contradiction detection and narrative facts (the pump station allegation supporting the County claim).
- `Correspondence/tidewater-denial-reservation-of-rights.pdf` — Born-digital denial / reservation-of-rights letter. Tests extraction of the basis for denial (citing the buried exclusion clause), the denial date, and the reservation-of-rights posture.
- `Correspondence/photos-transmittal-from-insured.eml` — Email from the insured's public adjuster transmitting loss photos as an attachment. Tests email parsing AND attachment-body extraction (a fact lives only in the attachment).
- `Correspondence/adjuster-internal-note.msg` — Outlook .msg the app cannot parse. Exercises the unsupported-import-report path. NO required answer-key Q&A depends on this file's content. *(unsupported — import report should flag it)*
- `Pleadings/sovereign-immunity-presuit-notice.pdf` — Born-digital § 768.28 pre-suit notice to Lee County and the Florida DFS. Tests extraction of the sovereign-immunity statutory basis, the damages cap, and ties the County tort theory to the insurance facts (supports cross-document synthesis).
- Plus real Florida authorities/procedure in `Caselaw & Procedure/`.

### Q&A scenarios (Documents → Ask)
| # | Question | Expected answer | Source | Flags |
|---|---|---|---|---|
| 1 | What is the policy number and the Coverage A (Dwelling) limit on the Tidewater Mutual policy? | Policy number TWM-FL-4471-2290; Coverage A (Dwelling) limit is $410,000. | `tidewater-policy-declarations.pdf` Declarations header and Section I — Property Coverages and Limits. |  |
| 2 | What deductibles apply, including any separate hurricane deductible? | An All-Other-Perils (AOP) deductible of $2,500 and a separate Hurricane Deductible of 2% of Coverage A, which equals $8,200. | `tidewater-policy-declarations.pdf` Deductibles section of the declarations page. |  |
| 3 | What is the claim number and the date of loss recorded on the first notice of loss form? | Claim number TWM-CLM-2024-100847; date of loss recorded on the form is 09/28/2024. | `claim-form-acord-scanned.pdf` Top of the scanned property loss notice (claim number) and the Date of Loss field. Image-only, requires OCR. | OCR |
| 4 | What total estimated replacement cost value (RCV) did the adjuster assign to the dwelling loss? | $148,750 (RCV). After recoverable depreciation of $19,300 and the $2,500 AOP deductible, the net ACV payable is $126,950. | `adjuster-damages-worksheet.xlsx` Summary sheet cell B9 (RCV) and B12 (net ACV); also LineItems 'Total RCV'. |  |
| 5 | Is there a contradiction in the date of loss across the file, and what are the two dates? | Yes. The scanned claim form states the date of loss as 09/28/2024, but Mrs. Calloway's recorded statement says the damage began the night of September 26, 2024. The two documents conflict on the date of loss. | `calloway-recorded-statement-transcript.docx` Compare the recorded statement's '26th' / late-husband's-birthday assertion against the claim form's Date of Loss field. Cross-document and requires OCR of the claim form. | OCR, cross-doc |
| 6 | On what policy provision did Tidewater Mutual base its denial? | Section I Exclusion 3(b), the Water Damage exclusion barring loss from flood, surface water, and overflow of a body of water (whether or not wind-driven), invoked together with the anti-concurrent-causation lead-in. | `tidewater-denial-reservation-of-rights.pdf` Body of the November 12, 2024 denial / reservation-of-rights letter quoting Exclusion 3(b). |  |
| 7 | What interior water line measurement is documented, and where does that figure come from? | An interior water line of 31 inches above the finished floor, documented in the photo log attached to Lorraine Tasker's October 22, 2024 email (it appears only in the attachment, not the email body). | `photos-transmittal-from-insured.eml` Attachment 'Calloway-photo-log.pdf', Photos 5-9 entry; not stated in the email body. |  |
| 8 | What statutory basis and damages cap govern the claim against Lee County? | Florida's sovereign immunity waiver, Fla. Stat. § 768.28, with a damages cap of $200,000 per person and $300,000 per incident absent a legislative claims bill; pre-suit written notice under § 768.28(6) is a condition precedent. | `sovereign-immunity-presuit-notice.pdf` Damages and compliance paragraphs of the § 768.28(6) notice of claim. |  |
| 9 | Does the sequence and timing of water intrusion support the argument that the County pump station failure, not just flood, contributed to the loss? | Yes. The recorded statement and the photo log together show wind-driven rain entered through the roof first (camera stamp ~SEP 26 11:38 PM), then ground/surface water rose later (camera stamp SEP 27 04:12 AM) after Lee County pump station #7 went silent, supporting a theory that the County's operational negligence contributed to the inundation, independent of the policy's flood exclusion. | `calloway-recorded-statement-transcript.docx` Synthesize the recorded statement (roof-first, then canal; pump #7 failure) with the photo-log timestamps in photos-transmittal-from-insured.eml and the § 768.28 notice. Cross-document. | cross-doc |
| 10 | Who is the named claims supervisor who signed the denial letter, and on what date was it issued? | Priya Venkataraman, Claims Supervisor, signed the denial / reservation-of-rights letter dated November 12, 2024. | `tidewater-denial-reservation-of-rights.pdf` Signature block and date line of the denial letter. |  |
| 11 | What was the amount of the insured's mortgage payoff balance with Gulfshore Community Bank at the time of loss? | NOT SUPPORTED — the documents do not answer this. The declarations name Gulfshore Community Bank as mortgagee but no payoff balance appears anywhere in the corpus. | `tidewater-policy-declarations.pdf` Mortgagee is named on the declarations, but no payoff figure exists in any document. | **must refuse** |
| 12 | What hurricane name did the National Hurricane Center assign to the storm that caused the loss? | NOT SUPPORTED — the documents do not answer this; the storm is referred to only generically as 'the hurricane' and no storm name is stated anywhere in the corpus. | `claim-form-acord-scanned.pdf` Documents say 'hurricane' generically; no named storm appears in any file. | **must refuse** |

### Chronology (Documents → Chronology)
| Date | Event | Source |
|---|---|---|
| 2023-11-01 | Tidewater Mutual policy TWM-FL-4471-2290 period begins (runs through 11/01/2024). | `tidewater-policy-declarations.pdf` |
| 2024-09-26 | Per the insured's recorded statement, the loss began the night of September 26, 2024: wind tore roof shingles and water entered through the bedroom ceiling, followed by canal flooding after county pump station #7 went silent. | `calloway-recorded-statement-transcript.docx` |
| 2024-09-28 | Date of loss as recorded on the scanned first-notice-of-loss form (contradicts the recorded statement's 09/26 date). | `claim-form-acord-scanned.pdf` |
| 2024-09-30 | Loss reported to Tidewater Mutual; claim TWM-CLM-2024-100847 opened. | `claim-form-acord-scanned.pdf` |
| 2024-10-03 | Adjuster Dennis Okafor takes the insured's recorded statement. | `calloway-recorded-statement-transcript.docx` |
| 2024-10-14 | Adjuster damages worksheet prepared; estimated RCV of $148,750 / net ACV payable $126,950. | `adjuster-damages-worksheet.xlsx` |
| 2024-10-22 | Public adjuster Lorraine Tasker emails loss photos and photo log (31-inch interior water line; sequence timestamps). | `photos-transmittal-from-insured.eml` |
| 2024-11-12 | Tidewater Mutual issues denial / reservation-of-rights letter relying on Exclusion 3(b) (flood/surface water). | `tidewater-denial-reservation-of-rights.pdf` |
| 2024-12-02 | Section 768.28(6) pre-suit notice of claim served on Lee County BoCC and Florida DFS for negligent operation of pump station #7. | `sovereign-immunity-presuit-notice.pdf` |

### CourtListener research
- **Issue:** Florida sovereign immunity for a tort claim against a county under Fla. Stat. § 768.28, including the planning-level vs. operational-level distinction for negligent operation/maintenance of a stormwater pump station, the statutory $200,000/$300,000 damages caps, and the § 768.28(6) pre-suit written-notice condition precedent.
- **Jurisdiction filter:** Florida (state courts; Fla. 2d/3d DCA and Florida Supreme Court authority)
- **Expected authorities:** Dowd v. Monroe County, 557 So. 2d 63 (Fla. 3d DCA 1990), Hirt v. Polk County Bd. of County Comm'rs, 578 So. 2d 415 (Fla. 2d DCA 1991), Commercial Carrier Corp. v. Indian River County, 371 So. 2d 1010 (Fla. 1979), Fla. Stat. § 768.28
