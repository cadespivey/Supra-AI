import { CapabilityGrid } from "@/components/CapabilityGrid";
import { FinalCta } from "@/components/FinalCta";
import { Hero } from "@/components/Hero";
import { PillarsSection } from "@/components/PillarsSection";
import { ProvidersSection } from "@/components/ProvidersSection";
import { ScreenshotShowcase } from "@/components/ScreenshotShowcase";
import { SourceGroundingStack } from "@/components/SourceGroundingStack";

export default function Home() {
  return (
    <main>
      <Hero />
      <ScreenshotShowcase />
      <SourceGroundingStack />
      <CapabilityGrid />
      <PillarsSection />
      <ProvidersSection />
      <FinalCta />
    </main>
  );
}
