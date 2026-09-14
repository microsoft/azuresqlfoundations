/*
    ZavaLendingDB — Add LoanNarrative Column
    SQLCon 2026 — Demo 2: "The Destination: Built for Hyperscale"
    
    Adds a rich text LoanNarrative column to LoanHistory.
    This column stores human-readable descriptions of each loan application,
    including context about the borrower's situation, purpose, and risk factors.
    
    This narrative text is what Demo 3 will try to search:
      - First with Full-Text Search (fails for natural language prompts)
      - Then with vector embeddings (succeeds beautifully)
    
    Target: zavafinsql.database.windows.net / zavalending
    Auth:   Access token (-T)
    
    Run with sqlsim:
      .\build\x64\Release\sqlsim.exe -S zavafinsql.database.windows.net -d zavalending -T <token> -i <this-file> -v
*/

-- ============================================
-- ADD LoanNarrative column (NVARCHAR(4000))
-- AI_GENERATE_EMBEDDINGS requires a sized NVARCHAR, not MAX.
-- ============================================
PRINT '=== Adding/verifying LoanNarrative column on LoanHistory ==='
GO

-- If column exists as NVARCHAR(MAX), we need to drop the FT index, alter it, then recreate.
-- If column doesn't exist, just add it as NVARCHAR(4000).
IF NOT EXISTS (
    SELECT 1 FROM sys.columns 
    WHERE object_id = OBJECT_ID('dbo.LoanHistory') 
    AND name = 'LoanNarrative'
)
BEGIN
    ALTER TABLE dbo.LoanHistory
    ADD LoanNarrative NVARCHAR(4000) NULL;
    PRINT '  Column added as NVARCHAR(4000).'
END
ELSE IF EXISTS (
    SELECT 1 FROM sys.columns c
    WHERE c.object_id = OBJECT_ID('dbo.LoanHistory')
    AND c.name = 'LoanNarrative'
    AND c.max_length = -1  -- NVARCHAR(MAX)
)
BEGIN
    -- Drop full-text index first (blocks ALTER COLUMN)
    IF EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('dbo.LoanHistory'))
    BEGIN
        DROP FULLTEXT INDEX ON dbo.LoanHistory;
        PRINT '  Full-text index dropped (will be recreated below).'
    END

    ALTER TABLE dbo.LoanHistory
    ALTER COLUMN LoanNarrative NVARCHAR(4000) NULL;
    PRINT '  Column altered from NVARCHAR(MAX) to NVARCHAR(4000).'
END
ELSE
    PRINT '  Column already exists as NVARCHAR(4000).'
GO

-- ============================================
-- POPULATE narratives for existing loan history
-- ============================================
PRINT '=== Populating LoanNarrative for existing rows ==='
GO

-- Auto Loans
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 1 THEN 'Experienced borrower with 5 years of stable employment seeking financing for a new SUV. Strong credit profile with moderate debt load. Income comfortably supports the requested monthly payments. The applicant has a clean repayment history on two prior auto loans. Primary vehicle needed for daily commute and family transportation in the Pacific Northwest.'
    WHEN 2 THEN 'Mid-career professional looking to finance a certified pre-owned sedan. Credit score is fair but trending upward after resolving a collections issue two years ago. Debt-to-income ratio is elevated but manageable given the shorter loan term requested. The applicant recently received a promotion with a 12% salary increase not yet reflected in tax returns.'
    WHEN 3 THEN 'High-income applicant with excellent credit seeking a new truck for combined personal and business use. Self-employed contractor with 8 years in the construction industry. Strong cash reserves and low debt utilization. Requesting a longer 72-month term to preserve working capital for business operations.'
    WHEN 4 THEN 'Applicant with fair credit and elevated debt-to-income ratio seeking a used SUV. Employment history shows two job changes in the past 18 months, though income has remained stable. The current auto loan has two late payments in the past year. Higher risk profile given the combination of credit blemishes and leveraged balance sheet.'
    WHEN 5 THEN 'Veteran borrower with excellent credit and low leverage seeking an electric vehicle. Long tenure with current employer and significant home equity provide a strong financial cushion. The applicant is consolidating from a lease to a purchase to take advantage of federal EV tax credits. Minimal risk given the overall financial picture.'
    WHEN 6 THEN 'First-time borrower with thin credit file and low income relative to the requested luxury vehicle amount. No prior auto loan history. Debt-to-income ratio exceeds 50% with the proposed payment, and employment tenure is under one year. The application lacks a co-signer and the requested vehicle depreciates rapidly. High probability of payment stress.'
    WHEN 7 THEN 'Solid middle-income applicant with good credit seeking a certified pre-owned vehicle from a franchise dealer. Stable employment in healthcare administration with consistent income for the past 6 years. Moderate debt load with a small student loan balance. The CPO warranty reduces collateral risk. Well-structured application.'
    WHEN 8 THEN 'Young professional with fair credit seeking a new midsize car. Short employment history and elevated DTI suggest the borrower is stretching for this purchase. Two credit card accounts are near their limits. The longer 72-month term increases the likelihood of being underwater on the loan if circumstances change. Moderate-to-high risk.'
    WHEN 9 THEN 'Experienced borrower with good credit and strong income seeking a modest used compact car. Low loan-to-value ratio and short 36-month term minimize lender exposure. The applicant has successfully repaid three prior auto loans without any delinquencies. Conservative request relative to income suggests disciplined financial management.'
    WHEN 10 THEN 'Dual-income household with excellent combined credit seeking a hybrid SUV. Primary earner has 7.5 years at a Fortune 500 company with strong benefits. Moderate DTI includes a mortgage and one other auto loan. The hybrid vehicle qualifies for state-level green energy incentives. Low-risk profile with well-documented income stability.'
    ELSE LoanNarrative
END
WHERE LoanType = 'Auto' AND LoanNarrative IS NULL;
GO

-- Personal Loans
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 11 THEN 'Borrower with good credit seeking a personal loan for debt consolidation. Currently carrying balances on four credit cards at average 22% APR. This consolidation would reduce the monthly payment by approximately $320 and cut the effective interest rate by more than half. Steady employment and moderate income support the application. Consolidation borrowers in this credit tier have historically shown strong repayment rates.'
    WHEN 12 THEN 'Homeowner seeking funds for a kitchen and bathroom renovation. Fair credit with improving trajectory — score has risen 40 points in the past year. Employment history is short at current employer but the applicant has 10+ years in the same industry. The renovation is expected to increase home equity by approximately $35,000, providing a financial rationale for the investment.'
    WHEN 13 THEN 'Healthcare professional with strong credit seeking a short-term personal loan for medical expenses following an unexpected surgical procedure. High income relative to the loan amount and excellent debt management history. The 24-month term and low DTI make this a straightforward approval. The applicant has an emergency fund but prefers to preserve liquidity.'
    WHEN 14 THEN 'Recent entrant to the workforce with very low credit score and minimal credit history seeking a large personal loan for vacation and lifestyle spending. Income barely covers existing obligations, and the proposed payment would push DTI above 55%. No collateral, no co-signer, and the stated loan purpose is entirely discretionary. This application represents significant credit risk with minimal justification.'
    WHEN 15 THEN 'Established professional with strong credit seeking a personal loan for wedding expenses. Stable dual-income household with conservative spending patterns. The applicant has a history of paying installment loans ahead of schedule. The requested amount is less than 30% of annual income and the 36-month term is well within budget. Low risk with clear repayment capacity.'
    ELSE LoanNarrative
END
WHERE LoanType = 'Personal' AND LoanNarrative IS NULL;
GO

-- Small Business Loans
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 16 THEN 'Experienced restaurant owner with 12 years of profitable operations seeking equipment financing for a kitchen expansion. The business has shown consistent year-over-year revenue growth of 8-12% and maintains healthy margins. The new equipment is expected to increase capacity by 40% to meet growing demand in the downtown district. Strong personal credit and business financials support this application.'
    WHEN 17 THEN 'Retail entrepreneur seeking expansion capital to open a second location. The existing store has been profitable for 5 years with a loyal customer base. The proposed location is in a higher-traffic area with lower rent per square foot. Business plan projects break-even within 14 months. The lender reduced the approved amount by $25K as a risk buffer given the execution risk of multi-location management.'
    WHEN 18 THEN 'Small business owner seeking inventory financing for a seasonal product line. The business has operated for 5 years but profit margins have been inconsistent, with two unprofitable quarters in the past 18 months. Working capital has been declining, and the applicant recently drew down a personal HELOC to cover business payroll. The combination of business instability and personal financial exposure elevates default risk.'
    WHEN 19 THEN 'First-time entrepreneur seeking startup capital for a technology venture. No business revenue history and the applicant has moderate personal credit with limited savings. The business plan relies on assumptions about market adoption that are unvalidated. No collateral beyond personal guarantee, and personal income from a part-time consulting role is insufficient to service the debt if the business fails to generate revenue within 12 months.'
    WHEN 20 THEN 'Seasoned commercial real estate operator with 20 years of experience and an excellent credit profile seeking renovation financing for a mixed-use property. The property is 85% occupied with long-term lease agreements. The renovation will upgrade building systems and add amenities to support a planned rent increase. Cash flow analysis shows the investment pays back within 3 years through increased rental income. Strong application with minimal risk.'
    ELSE LoanNarrative
END
WHERE LoanType = 'SmallBusiness' AND LoanNarrative IS NULL;
GO

-- HomeImprovement Loans (rows 21-30)
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 21 THEN 'Long-time homeowner with good credit undertaking a full kitchen remodel to modernize a 25-year-old layout. The contractor estimate is well-documented with permits already filed. The home has significant equity and the renovation is expected to increase resale value by $60K. Stable dual-income household with manageable debt. The 60-month term keeps payments comfortable within the family budget.'
    WHEN 22 THEN 'Young couple adding a master suite bathroom to their starter home purchased 3 years ago. Fair credit with improving trajectory as they build payment history. The project addresses a functional gap — the home currently has only one full bathroom for a family of four. Income supports the payment, though DTI is moderate. The contractor is licensed and bonded with good references.'
    WHEN 23 THEN 'Professional couple finishing their basement to create a multi-purpose recreation and guest space. The home was purchased 8 years ago with substantial equity buildup. Good credit and strong dual income, though the requested amount was trimmed by $5K as a buffer. The renovation includes egress windows required by code, adding a conforming bedroom. Well-planned project with clear value-add.'
    WHEN 24 THEN 'Environmentally conscious homeowner installing rooftop solar panels on a paid-off property. Excellent credit with minimal debt and strong income. Federal and state tax credits will offset approximately 30% of the installation cost. The system is projected to eliminate the $280 monthly electric bill, making this both an environmental and financial investment. Low risk given the strong financial profile and collateral position.'
    WHEN 25 THEN 'Recent inheritor seeking a large renovation loan for a property in significant disrepair. The property needs roof replacement, foundation work, updated electrical, and new plumbing. The borrower has limited income relative to the project scope, below-average credit, and only 2 years of employment history. The inherited property has no mortgage but the renovation cost may exceed the post-renovation market value in the current neighborhood. High execution and financial risk.'
    WHEN 26 THEN 'Suburban homeowner building a composite deck with an outdoor kitchen and pergola. Good credit and stable employment in manufacturing management. The project enhances livability for a family that entertains frequently. The home has a conventional mortgage with 40% equity. The loan amount is reasonable relative to income and the improvement is expected to add $25K in property value.'
    WHEN 27 THEN 'Senior professional replacing a 30-year-old roof and adding spray foam insulation to improve energy efficiency. Excellent credit with very low debt utilization and a paid-off mortgage. The home inspection report documents the urgent need for roof replacement before the next winter season. The insulation upgrade qualifies for utility company rebates. Conservative borrower with strong repayment capacity.'
    WHEN 28 THEN 'Homeowner replacing a failed HVAC system in a 20-year-old home before summer. Fair credit with elevated debt including two car payments and a student loan. The HVAC failure is an emergency — the family is using portable units. The loan amount covers a high-efficiency system with a 15-year warranty. The borrower has been making minimum payments on existing debts, and adding this payment stretches the budget.'
    WHEN 29 THEN 'Remote worker converting an attached two-car garage into a professional home office with separate entrance. Good credit and strong income from a technology company that transitioned to permanent remote work. The conversion includes insulation, drywall, electrical, HVAC extension, and a powder room. Permits have been approved. The dedicated workspace is expected to increase both productivity and home value.'
    WHEN 30 THEN 'Homeowner investing in landscape design, hardscaping, and an in-ground pool. Good credit with moderate debt, including a sizable mortgage. The project is well-planned with a licensed pool contractor, though the total cost was reduced from the original $85K request. The pool addition may increase insurance costs. Income supports the payment but the combined home-related debt is approaching the upper comfort zone.'
    ELSE LoanNarrative
END
WHERE LoanType = 'HomeImprovement' AND LoanNarrative IS NULL;
GO

-- Additional Auto Loans (rows 31-45)
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 31 THEN 'Mid-level manager seeking a certified pre-owned SUV from a franchise dealer. Good credit with a clean payment history across three prior installment loans. Income comfortably supports the monthly payment alongside a modest mortgage. The CPO vehicle comes with manufacturer warranty extension, reducing collateral risk. Straightforward application with low risk.'
    WHEN 32 THEN 'Senior executive purchasing a new luxury sedan for daily commuting. Excellent credit with high income and low debt utilization. The applicant requested $55K but the lender trimmed the approval to $50K to align with the vehicle depreciation curve on the 72-month term. Strong home equity and retirement accounts provide additional financial cushion. Premium insurance coverage confirmed.'
    WHEN 33 THEN 'Young professional purchasing a used economy car for a 45-mile daily commute. Fair credit with some past credit card delinquencies that are now resolved. Limited employment history at only 2 years, but the employer is stable. The short 36-month term and modest loan amount keep the monthly payment manageable despite the higher interest rate. The vehicle is reliable transportation-focused.'
    WHEN 34 THEN 'Entry-level worker with poor credit applying for a new sports car well beyond their income capacity. The requested vehicle is a performance model with high insurance costs. The borrower has no prior auto loan history and current income barely covers rent and existing obligations. DTI would exceed 55% with this payment. No co-signer available and no down payment offered. High likelihood of payment default.'
    WHEN 35 THEN 'Dual-income family purchasing a new minivan as their primary family vehicle. Excellent credit with a strong track record of installment loan repayment. Three children require the larger vehicle as the existing sedan is no longer practical. Both earners have stable government employment with predictable income. Conservative financial management with significant emergency savings.'
    WHEN 36 THEN 'Tradesperson purchasing a used pickup truck for work use. Fair credit with some inconsistency in payment history during a period of seasonal unemployment two years ago. Income has stabilized with year-round employment at a construction company. The truck is essential for the job — the employer requires workers to provide their own transportation and hauling. Moderate risk given income sufficiency but credit history concerns.'
    WHEN 37 THEN 'Software engineer purchasing a new compact SUV for daily driving. Good credit with stable employment at a tech company for 7 years. Low debt utilization with only a small student loan remaining. The modest vehicle choice relative to income suggests disciplined finances. The applicant is putting 15% down, reducing lender exposure on the 60-month term.'
    WHEN 38 THEN 'High-income professional purchasing a premium electric SUV. Excellent credit with minimal debt and substantial investment portfolio. The applicant has been leasing luxury vehicles for a decade and is transitioning to ownership to take advantage of EV tax credits. The long 72-month term was approved with a slight reduction from the MSRP to account for battery depreciation considerations.'
    WHEN 39 THEN 'Borrower rebuilding credit after a Chapter 7 bankruptcy discharged 3 years ago. Currently employed as a warehouse supervisor with stable income. The used sedan is a practical necessity for commuting. The elevated interest rate reflects the credit risk, but the short term and moderate amount keep payments manageable. This is the applicant first major credit obligation since the discharge. Rebuilding history is fragile.'
    WHEN 40 THEN 'Experienced teacher purchasing a new fuel-efficient hatchback for a 30-mile daily commute. Good credit with consistent payment history on a prior auto loan that was paid off early. The fuel savings compared to the current vehicle will offset approximately $120/month. Well-structured request with a reasonable amount relative to stable income. Low risk profile.'
    WHEN 41 THEN 'Outdoor enthusiast purchasing a new midsize SUV with towing package for recreational use. Excellent credit with strong dual household income and low leverage. The vehicle will tow a travel trailer purchased last year. The applicant has a history of conservative borrowing with early payoffs. Insurance covers both the vehicle and towed assets. Solid application with minimal risk concerns.'
    WHEN 42 THEN 'Recent hire at a distribution center seeking a used compact car for basic transportation. Poor credit resulting from medical collections and a repossession 18 months ago. Income is limited and mostly consumed by rent and child support obligations. The short term keeps total interest manageable but monthly payments are tight relative to disposable income. The vehicle is an older model with higher maintenance risk.'
    WHEN 43 THEN 'Technology professional purchasing a new hybrid sedan for a moderate commute. Excellent credit with high income, minimal debt, and 10 years of stable employment. The hybrid configuration reduces fuel costs and qualifies for a state clean-vehicle rebate. The applicant is making a 20% down payment, resulting in a low loan-to-value ratio. Premium credit profile with excellent repayment capacity.'
    WHEN 44 THEN 'Recent college graduate with limited credit history aspiring to purchase a new luxury SUV. The applicant started a well-paying job 6 months ago but has no prior installment loan history. The requested vehicle is a status purchase with an MSRP nearly equal to annual income. No savings for a down payment and no co-signer despite parental encouragement to apply. Debt-to-income would be unsustainable at this price point.'
    WHEN 45 THEN 'Growing family purchasing a certified pre-owned station wagon. Good credit with stable employment in education. The applicant traded in a subcompact that no longer fits two car seats. The CPO warranty and franchise dealer service history reduce vehicle risk. The 48-month term and moderate amount result in comfortable payments. Thoughtful vehicle choice reflecting practical needs over aspirations.'
    ELSE LoanNarrative
END
WHERE LoanType = 'Auto' AND LoanId BETWEEN 31 AND 45 AND LoanNarrative IS NULL;
GO

-- Additional Personal Loans (rows 46-60)
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 46 THEN 'Homeowner with good credit seeking an emergency personal loan after a burst pipe caused significant water damage. Insurance covers structural repairs but not the replacement of personal belongings and additional living expenses during remediation. Stable employment in accounting with predictable income. The short 24-month term reflects the borrower desire to retire the debt quickly. Low risk given strong financials and urgent need.'
    WHEN 47 THEN 'Working parent seeking a personal loan for dental surgery not covered by insurance. Fair credit with a history of on-time payments on existing accounts despite limited income. The procedure is medically necessary — the dentist has documented progressive bone loss requiring surgical intervention. The short term keeps payments manageable. The borrower budget is tight but the medical necessity is clear.'
    WHEN 48 THEN 'Dual-income household consolidating $42K in credit card debt accumulated during a period of medical leave and reduced income. Fair credit with recent improvement as the second earner returned to full-time work. The consolidated payment would be $280 less per month than the combined minimum payments. The lender approved $30K of the $35K requested as a risk buffer. Financial trajectory is improving but still carries execution risk.'
    WHEN 49 THEN 'Unemployed individual seeking a large personal loan to invest in cryptocurrency and NFT trading. No verifiable income beyond sporadic freelance work. Very low credit score with multiple collections accounts and a recent charge-off. The stated loan purpose is entirely speculative with no guaranteed return. The applicant has no collateral, no co-signer, and no savings. Application represents extreme credit risk.'
    WHEN 50 THEN 'Married couple seeking a personal loan to cover international adoption expenses including travel, legal fees, and agency costs. Strong credit with excellent dual income and conservative spending. Both borrowers have long employment histories with Fortune 500 companies. The 36-month term is well within budget with significant disposable income remaining. The emotional investment in the adoption provides strong repayment motivation.'
    WHEN 51 THEN 'Young professional relocating cross-country for a new job with a 40% salary increase. Fair credit with a short history but no derogatory marks. Moving expenses include deposit, first/last month rent, moving company, and temporary storage. The new employer does not offer relocation assistance. The short 12-month term and small amount are manageable even at the higher rate. Practical purpose with clear repayment path.'
    WHEN 52 THEN 'First-time homebuyer seeking a personal loan to furnish a newly purchased house. Excellent credit with strong income from a medical practice. The home purchase was completed with 20% down, and the borrower prefers a personal loan to preserve the low mortgage rate rather than refinancing. The furniture purchases are from quality manufacturers with delivery timelines that match the loan funding schedule. Low risk profile.'
    WHEN 53 THEN 'Mid-career professional seeking a personal loan to fund an executive MBA at a top-tier business school. Good credit with solid income from a management consulting role. The employer will reimburse 50% of tuition upon completion, effectively halving the borrower net cost. The degree is expected to increase earning potential by $30-40K annually. The 48-month term bridges the gap until employer reimbursement and salary increase. Calculated investment with manageable risk.'
    WHEN 54 THEN 'Part-time retail worker seeking a personal loan for an extended international travel sabbatical. Poor credit caused by a pattern of late payments and a defaulted phone financing plan. Income is insufficient to service the proposed payment alongside rent and existing obligations. The travel purpose is entirely discretionary with no financial return. No savings or assets to serve as a safety net. High risk with discretionary purpose.'
    WHEN 55 THEN 'Single parent seeking a personal loan to cover co-pays and deductibles for a child ongoing medical treatment. Good credit and stable employment in city government. The medical bills have been accumulating over 8 months and the borrower wants to consolidate them into a single predictable payment. Health insurance covers 70% but the remaining 30% totals $20K. Strong repayment motivation given the ongoing medical needs and family responsibility.'
    WHEN 56 THEN 'Homeowner seeking a personal loan to cover deductible and repair costs after a car accident. Fair credit with slightly elevated DTI from a recent home purchase. The insurance claim is processing but the borrower needs the vehicle repaired immediately for commuting. The 24-month term bridges the gap until insurance reimbursement may reduce or retire the balance. Moderate risk offset by clear repayment source.'
    WHEN 57 THEN 'Affluent professional seeking a personal loan to install an in-ground pool and outdoor patio at their primary residence. Excellent credit with very low debt relative to high income. The home has $350K in equity and the improvement is expected to add significant value. The borrower prefers a personal loan to a HELOC to avoid tying the home to the project. Conservative financial approach from a strong borrower.'
    WHEN 58 THEN 'Couple seeking a personal loan to finance a second round of IVF fertility treatment after the first round was unsuccessful. Good credit with stable dual income. The clinic requires payment upfront and the couple has exhausted their savings on the first attempt. Health insurance does not cover fertility treatments in their state. The emotional and financial stakes are high, and the borrowers are committed to making this work within their budget.'
    WHEN 59 THEN 'Aspiring entrepreneur seeking a personal loan to fund a food truck startup. Below-average credit with a history of late payments on student loans during a period of underemployment. No business plan or revenue projections provided. The applicant has no experience in food service and no permits have been obtained. Personal income from a part-time delivery job is insufficient to service the debt. High risk with speculative purpose and weak financials.'
    WHEN 60 THEN 'Professional musician purchasing a concert grand piano for a home studio and teaching practice. Good credit with stable income from a university music department position supplemented by private lesson revenue. The instrument is both a professional tool and an appreciating asset. The 36-month term keeps payments comfortable alongside the mortgage. The borrower has a 15-year track record of conservative financial management.'
    ELSE LoanNarrative
END
WHERE LoanType = 'Personal' AND LoanId BETWEEN 46 AND 60 AND LoanNarrative IS NULL;
GO

-- Additional SmallBusiness Loans (rows 61-80)
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 61 THEN 'Family bakery expanding after 10 years of profitable operations. Adding a second commercial oven, expanding seating to 40, and renovating the storefront. Revenue has grown 15% annually for the past 3 years. The owner has excellent personal credit and the business maintains 6 months of operating reserves. The expansion is driven by consistent customer demand exceeding current capacity during weekend hours.'
    WHEN 62 THEN 'Independent auto repair shop seeking equipment upgrades including a new lift, diagnostic computer, and alignment machine. The shop has been profitable for 6 years serving a loyal customer base. Fair-to-good credit with moderate personal debt from a recent home purchase. The equipment upgrade is necessary to service newer vehicle models and maintain competitiveness. Lender reduced the approved amount as a risk buffer.'
    WHEN 63 THEN 'First-time business owner building out a food truck for a gourmet taco concept. Limited business experience with only 4 years of employment in restaurant kitchens. Fair credit with some credit card delinquencies during a transition between jobs. The food truck market is saturated in the target area with 15 competitors within 5 miles. Business plan projections are optimistic and unvalidated. Personal income cannot service the debt if the business fails.'
    WHEN 64 THEN 'Commercial real estate investor with over two decades of experience acquiring an office building in a growing suburban market. Impeccable credit with a diversified portfolio of 8 properties generating consistent rental income. The target building is 90% leased with credit tenants on 5-10 year terms. Cash flow analysis demonstrates a 12% cap rate. The 120-month term aligns with the long-term hold strategy. Minimal risk.'
    WHEN 65 THEN 'Aspiring e-commerce entrepreneur with no business track record seeking inventory financing for a dropshipping concept. Low credit score with multiple maxed-out credit cards and a pattern of minimum payments. The business model has extremely thin margins and depends on algorithms for customer acquisition. No physical assets or inventory to collateralize. The applicant quit their job 3 months ago to pursue this full-time with no revenue generated yet.'
    WHEN 66 THEN 'Established dental practice seeking to purchase a digital X-ray system and intraoral scanner to modernize patient care. The practice has been profitable for 14 years with a patient base of over 3,000 active records. Excellent personal credit and the business generates consistent monthly cash flow. The equipment purchase will reduce film costs by $2,000/month and attract patients seeking modern dental technology.'
    WHEN 67 THEN 'Experienced food service professional acquiring a franchise coffee shop in a high-traffic suburban location. Strong personal credit and 16 years of restaurant management experience. The franchise brand has 95% unit-level profitability across its 200+ locations. The lease terms are favorable with a 10-year commitment. The lender approved a slightly reduced amount to ensure adequate working capital reserves beyond the franchise fee.'
    WHEN 68 THEN 'Landscaping company owner seeking to expand the vehicle fleet with two new trucks and a trailer. Fair credit with some payment inconsistency during the off-season months when revenue drops. The business has been operating for 5 years but financial records are informal. The fleet expansion is needed to service three new commercial contracts, but the contracts are handshake agreements without written commitments.'
    WHEN 69 THEN 'Precision manufacturing firm purchasing a CNC machining center to expand production capacity. The company has 18 years of profitable operations with a blue-chip customer base including aerospace and medical device companies. Excellent personal and business credit. Current backlog is 14 months and the new machine will reduce lead times by 40%. The loan is fully supported by existing purchase orders. Exceptional application.'
    WHEN 70 THEN 'First-time business owner opening a pet grooming salon in a strip mall with high foot traffic. Below-average credit with limited employment history including two years as a pet grooming employee. The startup costs include build-out, equipment, insurance, and three months of working capital. The business plan is basic with no formal market analysis. The applicant personal savings cover only 10% of startup costs. Significant execution risk.'
    WHEN 71 THEN 'Seasoned hospitality operator renovating a 24-room boutique hotel acquired at below-market value in a coastal tourism destination. Outstanding credit with extensive experience operating three other hotel properties. The renovation plan includes room upgrades, lobby redesign, and addition of a rooftop bar. The post-renovation room rate is projected to increase from $159 to $289 per night. Strong market fundamentals and operator experience minimize risk.'
    WHEN 72 THEN 'Fitness professional opening a boutique gym and personal training studio. Good credit with 7 years of experience as a trainer at a national chain. The equipment package includes commercial-grade machines, free weights, and specialized training apparatus. The location is in an underserved area with growing residential development. Member pre-sales have generated 60 commitments before opening day.'
    WHEN 73 THEN 'Aspiring restaurateur seeking to open a third location of a struggling restaurant concept. The first two locations are break-even at best with inconsistent food costs and high staff turnover. Below-average personal credit with recent late payments on a business credit card. The proposed location is in a competitive dining district with 12 restaurants within two blocks. Cash flow projections rely on assumptions that contradict the existing locations performance.'
    WHEN 74 THEN 'Growing veterinary clinic purchasing digital X-ray and ultrasound equipment to expand diagnostic capabilities. Excellent credit with 12 years of veterinary practice experience. The clinic serves over 5,000 active pet families and has consistently grown revenue at 10% annually. The equipment will eliminate the need to refer patients to a veterinary hospital for imaging, capturing an estimated $8,000/month in retained revenue.'
    WHEN 75 THEN 'Former teacher launching a tutoring and test preparation center in a suburban community with highly rated schools. Fair credit with stable income from tutoring side work during the past 5 years. The center will offer SAT/ACT prep, subject tutoring, and college counseling. Startup costs include classroom build-out, furniture, and initial marketing. The applicant has relationships with 40 families from private tutoring. Moderate risk with niche market focus.'
    WHEN 76 THEN 'Third-generation winery expanding barrel storage and building a dedicated tasting room for wine club members and visitors. Excellent credit and the family business has operated profitably for 45 years with national distribution. The expansion supports a direct-to-consumer strategy that generates 3x higher margins than wholesale distribution. Planning permits are approved and the contractor is under contract. Strong legacy business with excellent fundamentals.'
    WHEN 77 THEN 'Dry cleaning operator opening a new location in a growing residential neighborhood. Fair-to-good credit with 8 years of experience running the original location profitably. The new site is in a recently developed mixed-use complex with guaranteed foot traffic from 200 residential units above the commercial space. Startup costs include equipment, lease deposit, and marketing. The operator proven track record reduces execution risk.'
    WHEN 78 THEN 'Aspiring mobile car wash operator seeking startup capital for a franchise opportunity. Below-average credit with inconsistent employment history spanning delivery driving and rideshare work. The franchise fee is $25K with additional costs for equipment and a wrapped vehicle. The applicant has limited savings and no prior business experience. The franchise support model helps but cannot guarantee success for an undercapitalized operator.'
    WHEN 79 THEN 'IT consulting firm expanding from a home office to a professional office suite and hiring two additional consultants. Good credit with 11 years of profitable operations serving small and medium businesses. Current clients have signed 3-year managed services agreements providing predictable recurring revenue. The office expansion supports a growth plan to double revenue within 24 months. Well-documented financials and clear business trajectory.'
    WHEN 80 THEN 'Craft brewery operators renovating a historic building into a taproom and microbrewery. Fair-to-good credit with 6 years of homebrewing awards and 3 years of contract brewing experience. The building is leased with a 10-year term and the landlord is contributing $20K toward build-out. Local zoning approval has been secured. The target market analysis shows the area currently has no craft brewery within 8 miles. Promising concept with moderate execution risk.'
    ELSE LoanNarrative
END
WHERE LoanType = 'SmallBusiness' AND LoanId BETWEEN 61 AND 80 AND LoanNarrative IS NULL;
GO

-- Additional Auto Loans in mixed batch (rows 81-83, 86, 88, 90, 92, 94, 96, 98, 100)
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 81 THEN 'Family seeking a new AWD crossover SUV for safe winter driving in a northern climate. Good credit with stable dual income and conservative spending habits. The current vehicle is a 12-year-old sedan with increasing repair costs and no all-wheel drive. The new vehicle provides safety features including automatic emergency braking and lane-keeping assist. Well-structured application with clear practical motivation.'
    WHEN 82 THEN 'Single parent purchasing a used minivan to accommodate a growing family. Fair credit with elevated DTI from child care expenses and a modest mortgage. The current vehicle has 180K miles and has failed two recent inspections. Transportation is essential for getting two children to school and driving to work at a distribution center. The higher interest rate reflects credit risk, but the vehicle is a practical necessity.'
    WHEN 83 THEN 'Technology professional purchasing a new electric truck for combined work and personal use. Excellent credit with high income from a remote engineering position. The truck will replace a diesel pickup used for a small hobby farm. Federal EV tax credits and elimination of fuel costs provide $4,800 in annual savings. Strong down payment of 25% reduces lender exposure. Conservative borrower with excellent financial reserves.'
    WHEN 86 THEN 'Single-income household with poor credit attempting to purchase a new midsize SUV. Recent divorce has resulted in a single income supporting a mortgage and two children. No savings for a down payment and DTI already exceeds 50% before the proposed car payment. The requested vehicle is more expensive than necessary for basic transportation. Co-signer declined. Financial profile cannot support this obligation.'
    WHEN 88 THEN 'Municipal employee purchasing a certified pre-owned electric vehicle for a 20-mile daily commute. Good credit with stable government employment and union benefits. The EV charging costs approximately $30/month compared to $250/month in gasoline for the current vehicle. The applicant is making a 10% down payment from tax refund savings. Practical purchase with clear cost savings and manageable payments.'
    WHEN 90 THEN 'Automotive enthusiast purchasing a new performance sedan as a secondary vehicle. Excellent credit with very high income from dual-earner household in technology and finance. The applicant owns their primary vehicle outright and maintains a substantial investment portfolio. The purchase is discretionary but well within financial means. Low DTI even with the additional payment. Minimal risk.'
    WHEN 92 THEN 'Budget-conscious buyer purchasing an off-lease luxury sedan at a significant discount from original MSRP. Fair credit with improving trajectory after managing credit card balances down over the past year. Stable employment in retail management for 4 years. The vehicle choice reflects good value — 3 years old with remaining factory warranty. Moderate risk with practical approach to vehicle acquisition.'
    WHEN 94 THEN 'Growing family purchasing a new plug-in hybrid SUV to replace a conventional sedan. Excellent credit with strong income and 9 years of stable employment. The family is expecting a third child and needs the additional passenger and cargo space. The plug-in hybrid provides EV-mode commuting with gasoline backup for longer trips. Down payment of 15% and moderate 60-month term result in comfortable payments.'
    WHEN 96 THEN 'Insurance adjuster purchasing a new sedan after their previous vehicle was totaled in a not-at-fault accident. Good credit with stable income and clear driving record. Insurance settlement covers 60% of the new vehicle cost. The replacement is needed immediately for work — the position requires daily driving to inspection sites. Well-motivated purchase with partial funding from insurance proceeds.'
    WHEN 98 THEN 'Recent college graduate purchasing a used hatchback as their first owned vehicle after using public transit throughout school. Fair credit with a short history — only a student credit card with 3 years of on-time payments. New employment in marketing at a mid-sized agency provides stable income. The modest vehicle choice and short term suggest financial awareness. The graduate student loan payments begin in 4 months.'
    WHEN 100 THEN 'Experienced professional purchasing a new AWD sedan for year-round reliable transportation in a mountainous region. Excellent credit with 10 years of employment at the same company and a history of responsible borrowing. Two prior auto loans were paid in full ahead of schedule. Low DTI and strong income make this a straightforward approval. The AWD capability is a practical necessity for winter road conditions.'
    ELSE LoanNarrative
END
WHERE LoanType = 'Auto' AND LoanId IN (81,82,83,86,88,90,92,94,96,98,100) AND LoanNarrative IS NULL;
GO

-- Additional Personal Loans in mixed batch (rows 84-85, 87, 89, 91, 93, 95, 97, 99)
UPDATE dbo.LoanHistory
SET LoanNarrative = CASE LoanId
    WHEN 84 THEN 'Homeowner seeking a personal loan to finish a basement renovation that was started but stalled due to an unexpected furnace replacement cost. Good credit with moderate income and manageable DTI. The basement is partially framed and requires drywall, flooring, electrical, and a bathroom rough-in. The renovation will add a conforming bedroom and increase the home value by an estimated $30K. Practical completion of an existing project.'
    WHEN 85 THEN 'Pet owner seeking an emergency personal loan for life-saving surgery on a 4-year-old dog diagnosed with a tumor. Fair credit with limited income from a retail management position. The veterinary surgeon quotes $7,000 for the procedure with a 90% success rate. The borrower has no pet insurance and limited savings. The short 12-month term keeps total interest low despite the higher rate. Emotional and practical urgency.'
    WHEN 87 THEN 'Career-changer seeking a personal loan to fund a professional pilot license including ground school, flight hours, and certification exams. Good credit with stable employment transitioning from accounting to aviation. The total training cost is $14K with an expected 40% salary increase upon obtaining the commercial certificate. The applicant has been saving for 2 years and is funding 50% of the cost from savings. Targeted investment in career development.'
    WHEN 89 THEN 'Engaged couple seeking a personal loan to cover wedding venue deposit, catering, and photography for a 150-person celebration. Fair credit with moderate dual income. The wedding budget is $28K total and the couple is funding $8K from savings. The remaining $20K is the loan request, though the lender approved $18K. Both borrowers have stable employment. The 36-month term means the loan will be paid before their planned home purchase.'
    WHEN 91 THEN 'Applicant seeking a personal loan for multiple elective cosmetic procedures including rhinoplasty and liposuction. Below-average credit with a history of opened and closed credit accounts suggesting financial instability. Income from a commission-based sales position is variable and unverifiable. The procedures are entirely elective with no medical necessity. No savings for a down payment. High risk with discretionary purpose.'
    WHEN 93 THEN 'Healthcare professional seeking a personal loan for LASIK corrective eye surgery on both eyes. Good credit with stable income from a hospital nursing position. The procedure eliminates the need for contact lenses and glasses, saving approximately $800/year in ongoing costs. The surgeon offers a financing plan but the personal loan rate is lower. Short 24-month term with comfortable payments relative to income.'
    WHEN 95 THEN 'Adult child seeking a personal loan to fund accessibility modifications and home safety upgrades for an aging parent home. Good credit with stable employment in financial services. The modifications include a stair lift, walk-in shower conversion, grab bars, improved lighting, and a first-floor bedroom reconfiguration. The parent home has no mortgage. This is a planned investment in the parent ability to age in place safely.'
    WHEN 97 THEN 'Homeowner with excellent credit seeking a personal loan for a comprehensive home security system and smart home automation upgrade. Strong income from a technology sales director position. The project includes security cameras, smart locks, automated lighting, a whole-house generator, and a centralized control system. The home is in an area with increasing property values and the upgrades add both security and market appeal.'
    WHEN 99 THEN 'Fitness enthusiast seeking a personal loan to build out a full home gym and wellness room including equipment, rubber flooring, mirrors, ventilation, and a cold plunge installation. Good credit with strong income from a dual-earner household. The investment replaces $400/month in gym memberships and personal training sessions for both partners. The 48-month payback period is offset by eliminated recurring fitness costs.'
    ELSE LoanNarrative
END
WHERE LoanType = 'Personal' AND LoanId IN (84,85,87,89,91,93,95,97,99) AND LoanNarrative IS NULL;
GO
SELECT LoanId, LoanType, LoanPurpose, 
       LEFT(LoanNarrative, 80) + '...' AS NarrativePreview,
       LEN(LoanNarrative) AS NarrativeLength
FROM dbo.LoanHistory
WHERE LoanNarrative IS NOT NULL
ORDER BY LoanId;
GO

-- ============================================
-- FULL-TEXT CATALOG + INDEX on LoanNarrative
-- (This is what Demo 3 will try to use first)
-- ============================================
PRINT '=== Creating Full-Text catalog and index ==='
GO

IF NOT EXISTS (SELECT 1 FROM sys.fulltext_catalogs WHERE name = 'FT_ZavaLending')
    CREATE FULLTEXT CATALOG FT_ZavaLending AS DEFAULT;
GO

IF NOT EXISTS (SELECT 1 FROM sys.fulltext_indexes WHERE object_id = OBJECT_ID('dbo.LoanHistory'))
BEGIN
    DECLARE @pkName NVARCHAR(256);
    SELECT @pkName = i.name
    FROM sys.indexes i
    WHERE i.object_id = OBJECT_ID('dbo.LoanHistory')
      AND i.is_primary_key = 1;

    DECLARE @sql NVARCHAR(MAX) = N'CREATE FULLTEXT INDEX ON dbo.LoanHistory(LoanNarrative) KEY INDEX ' + QUOTENAME(@pkName) + N' ON FT_ZavaLending WITH CHANGE_TRACKING AUTO';
    EXEC sp_executesql @sql;
END
GO

PRINT '=== Done. LoanHistory now has rich text narratives and Full-Text indexing. ==='
GO
